import Foundation
@testable import DesksetCore

// Baseline fixtures for the numerical phase still implemented by Measure. All expected values are literals:
// in particular, the actual implementation observes the averaged value before applying inversion.
private struct MeasureNumericReading: Equatable {
    let value: Double
    let minimum: Double
    let maximum: Double
    let updates: Int
}

private func numericReading(_ measure: Measure) -> MeasureNumericReading {
    MeasureNumericReading(value: measure.value, minimum: measure.minValue,
                          maximum: measure.maxValue, updates: measure.updateCount)
}

private final class MeasureNumericHost: FakeHost {
    override func environment(for skin: Skin) -> SkinEnvironment {
        SkinEnvironment(settingsPath: "/fixture/Settings/", programPath: "/fixture/Program/",
                        configEditor: "/fixture/Editor", locale: Locale(identifier: "en_US_POSIX"),
                        preferredLanguages: ["en"])
    }
}

private final class MeasureNumericSystem: FakeSystem {
    private(set) var cpuReads = 0

    override func cpuUsage(processor: Int) -> Double {
        cpuReads += 1
        return super.cpuUsage(processor: processor)
    }
}

private enum MeasureNumericFixtureError: Error { case utcUnavailable }

private func measureNumericSkin(_ t: TestRunner, _ ini: String, system: FakeSystem = FakeSystem())
    throws -> (Skin, MeasureNumericHost) {
    let skins = t.temporaryDirectory("measure-numeric-pipeline").appendingPathComponent("Skins")
    let directory = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("Skin.ini")
    try ini.write(to: url, atomically: true, encoding: .utf8)
    guard let utc = TimeZone(secondsFromGMT: 0) else { throw MeasureNumericFixtureError.utcUnavailable }
    let host = MeasureNumericHost()
    let skin = Skin(config: "Root\\Sub", fileURL: url, skinsDirectory: skins, system: system, host: host)
    skin.skinClock = .fixed(Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc, uptime: 86_400)
    skin.random = SkinRandom(seed: 1)
    try skin.load()
    t.equal(host.logs, [], "the numerical fixture loads without actions or diagnostics")
    return (skin, host)
}

private enum MeasureNumericFixtures {
    static let average = """
    [Variables]
    Raw=0

    [Average]
    Measure=Calc
    Formula=#Raw#
    DynamicVariables=1
    AverageSize=2
    """

    static let automaticBounds = """
    [Probe]
    Measure=NumericRangeHookProbe
    ProbeMinimum=-2
    ProbeSpan=12
    ProbeSample=7
    """

    static let pinned = """
    [CPU]
    Measure=CPU
    AverageSize=2
    InvertMeasure=1
    MinValue=0
    MaxValue=100
    OnUpdateAction=[!Log "cpu:[CPU:]"]
    """
}

private enum MeasureNumericHook: Equatable {
    case options(minimum: Double, span: Double, sample: Double)
    case compute(Double)
    case minimum(Double)
    case maximum(minimum: Double, span: Double)
}

// Uses the existing public subclass and registration seams. The automatic maximum deliberately reads the
// just-published minimum, and compute changes the automatic minimum, so an eager snapshot has different results.
private final class NumericRangeHookProbe: Measure {
    var events: [MeasureNumericHook] = []
    private var lower = 0.0
    private var span = 0.0
    private var sample = 0.0

    override func readMeasureOptions() {
        lower = double("ProbeMinimum", 0)
        span = double("ProbeSpan", 0)
        sample = double("ProbeSample", 0)
        events.append(.options(minimum: lower, span: span, sample: sample))
    }

    override var automaticMinValue: Double {
        events.append(.minimum(lower))
        return lower
    }

    override var automaticMaxValue: Double {
        events.append(.maximum(minimum: minValue, span: span))
        return minValue + span
    }

    override func computeValue() -> Double {
        events.append(.compute(sample))
        lower = sample
        return sample
    }
}

func runMeasureNumericPipelineTests(_ t: TestRunner) {
    t.suite("Engine: measure numeric pipeline: average observations and window changes") {
        let (skin, host) = try measureNumericSkin(t, MeasureNumericFixtures.average)
        defer { withExtendedLifetime(host) { skin.close() } }
        guard let measure = skin.measure(named: "Average") else {
            t.check(false, "Average was not constructed")
            return
        }
        var readings: [MeasureNumericReading] = []
        func update(_ raw: String, options: String = "") {
            if !options.isEmpty { skin.execute(options, from: nil) }
            skin.setVariable("Raw", raw)
            skin.update()
            readings.append(numericReading(measure))
        }

        update("0")
        update("12")
        update("18", options: "[!SetOption Average AverageSize 4]")
        update("30", options: "[!SetOption Average AverageSize 3]")
        update("-6", options: "[!SetOption Average AverageSize 2]")
        update("54", options: "[!SetOption Average MaxValue 4]")
        update("-54", options: "[!SetOption Average MaxValue \"\"]")
        update("8", options: "[!SetOption Average AverageSize 1]")
        update("20", options: "[!SetOption Average AverageSize 2]")

        t.equal(readings, [
            .init(value: 0, minimum: 0, maximum: 1, updates: 1),
            .init(value: 6, minimum: 0, maximum: 6, updates: 2),
            .init(value: 10, minimum: 0, maximum: 10, updates: 3),
            .init(value: 16, minimum: 0, maximum: 16, updates: 4),
            .init(value: -6, minimum: -6, maximum: 16, updates: 5),
            .init(value: 24, minimum: -6, maximum: 4, updates: 6),
            .init(value: 0, minimum: -6, maximum: 24, updates: 7),
            .init(value: 8, minimum: -6, maximum: 24, updates: 8),
            .init(value: 20, minimum: -6, maximum: 24, updates: 9),
        ], "average before observation; retain fitting history, reset oversized/disabled history, remember hidden bounds")
        t.equal(host.logs, [], "valid resize and range changes emit no diagnostics")
    }

    t.suite("Engine: measure numeric pipeline: automatic bounds are read at their original points") {
        MeasureRegistry.registerMeasure("NumericRangeHookProbe", NumericRangeHookProbe.self)
        let (skin, host) = try measureNumericSkin(t, MeasureNumericFixtures.automaticBounds)
        defer { withExtendedLifetime(host) { skin.close() } }
        guard let probe = skin.measure(named: "Probe") as? NumericRangeHookProbe else {
            t.check(false, "the registered numerical probe was not constructed")
            return
        }
        t.equal(probe.events, [
            .options(minimum: -2, span: 12, sample: 7), .minimum(-2), .maximum(minimum: -2, span: 12),
        ], "type options precede the first automatic bounds; maximum sees the new minimum")
        t.equal(numericReading(probe), .init(value: 0, minimum: -2, maximum: 10, updates: 0))

        probe.events.removeAll()
        skin.update()
        t.equal(probe.events, [.compute(7), .minimum(7), .maximum(minimum: 7, span: 12)],
                "a normal tick reads the automatic bounds after compute changes them")
        t.equal(numericReading(probe), .init(value: 7, minimum: 7, maximum: 19, updates: 1))

        probe.events.removeAll()
        skin.execute("[!SetOption Probe MinValue 3]", from: nil)
        skin.update()
        t.equal(probe.events, [
            .options(minimum: -2, span: 12, sample: 7), .maximum(minimum: 3, span: 12),
            .compute(7), .maximum(minimum: 3, span: 12),
        ], "an explicit minimum suppresses its getter during both option reading and updating")
        t.equal(numericReading(probe), .init(value: 7, minimum: 3, maximum: 15, updates: 2))

        probe.events.removeAll()
        skin.execute("[!SetOption Probe MaxValue 40]", from: nil)
        skin.update()
        t.equal(probe.events, [.options(minimum: -2, span: 12, sample: 7), .compute(7)],
                "two explicit bounds suppress both getters")
        t.equal(numericReading(probe), .init(value: 7, minimum: 3, maximum: 40, updates: 3))

        probe.events.removeAll()
        skin.execute("[!SetOption Probe MinValue \"\"]", from: nil)
        skin.update()
        t.equal(probe.events, [
            .options(minimum: -2, span: 12, sample: 7), .minimum(-2), .compute(7), .minimum(7),
        ], "an explicit maximum suppresses only its getter")
        t.equal(numericReading(probe), .init(value: 7, minimum: 7, maximum: 40, updates: 4))

        probe.events.removeAll()
        skin.execute("[!SetOption Probe MaxValue \"\"][!SetOption Probe ProbeMinimum -6]"
                     + "[!SetOption Probe ProbeSpan 20][!SetOption Probe ProbeSample 11]", from: nil)
        skin.update()
        t.equal(probe.events, [
            .options(minimum: -6, span: 20, sample: 11), .minimum(-6), .maximum(minimum: -6, span: 20),
            .compute(11), .minimum(11), .maximum(minimum: 11, span: 20),
        ], "removing explicit bounds restores fresh type-option and post-compute automatic reads")
        t.equal(numericReading(probe), .init(value: 11, minimum: 11, maximum: 31, updates: 5))
        t.equal(host.logs, [], "the hook fixture has no inverted ranges or invalid options")
    }

    t.suite("Engine: measure numeric pipeline: pinned values leave the live average intact") {
        let system = MeasureNumericSystem()
        let (skin, host) = try measureNumericSkin(t, MeasureNumericFixtures.pinned, system: system)
        defer { withExtendedLifetime(host) { skin.close() } }
        guard let measure = skin.measure(named: "CPU") else {
            t.check(false, "CPU was not constructed")
            return
        }
        var readings: [MeasureNumericReading] = []
        var systemReads: [Int] = []
        func update() {
            skin.update()
            readings.append(numericReading(measure))
            systemReads.append(system.cpuReads)
        }

        system.cpu = 20
        update()
        let sample = MeasureValueOverride()
        sample.pinned["cpu"] = (value: 90, text: nil)
        skin.measureValues = sample
        system.cpu = 97
        update()
        sample.pinned.removeAll()
        system.cpu = 40
        update()

        t.equal(readings, [
            .init(value: 80, minimum: 0, maximum: 100, updates: 1),
            .init(value: 90, minimum: 0, maximum: 100, updates: 2),
            .init(value: 70, minimum: 0, maximum: 100, updates: 3),
        ], "pin bypasses average and inversion; resumed live data averages only 20 and 40")
        t.equal(systemReads, [1, 1, 2], "a pinned tick does not read the live processor")
        t.equal(host.logs, ["Notice: cpu:80", "Notice: cpu:90", "Notice: cpu:70"],
                "OnUpdateAction still runs once for each tick, including the pinned tick")
    }
}
