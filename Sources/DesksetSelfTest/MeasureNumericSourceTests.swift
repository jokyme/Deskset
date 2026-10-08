import Foundation
@testable import DesksetCore

private enum NumericSourceEvent: Equatable {
    case refresh, minimum
    case maximum(afterMinimum: Double)
    case number(String), boolean(String), integer(String)
    case log(SkinLogLevel, String)
}

/// A numerical producer with no Skin, Measure or app host. The production pipeline owns all history.
private final class IndependentNumericSource: MeasureNumericSource {
    let name = "NumericSource"
    let pipeline: MeasurePipeline
    var value = 0.0
    var rawString: String?
    var minValue = 0.0
    var maxValue = 1.0
    var invert = false
    var averageSize = 0
    var computedPlaceholder = false
    var tracksValueRange = true
    var allowsMinValueOption = true
    var allowsMaxValueOption = true
    var allowsInvert = true
    var allowsAverage = true
    var rangeOptionScale = 1.0
    var lower = 0.0
    var upper = 1.0
    var span: Double?
    var numbers: [String: Double] = [:]
    var integers: [String: Int] = [:]
    var booleans: [String: Bool] = [:]
    var events: [NumericSourceEvent] = []
    var onLog: (() -> Void)?

    init(pipeline: MeasurePipeline = MeasurePipeline()) { self.pipeline = pipeline }
    var automaticMinValue: Double { events.append(.minimum); return lower }
    var automaticMaxValue: Double {
        events.append(.maximum(afterMinimum: minValue))
        return span.map { minValue + $0 } ?? upper
    }
    func bool(_ key: String, _ defaultValue: Bool) -> Bool {
        events.append(.boolean(key)); return booleans[key] ?? defaultValue
    }
    func int(_ key: String, _ defaultValue: Int) -> Int {
        events.append(.integer(key)); return integers[key] ?? defaultValue
    }
    func optionalDouble(_ key: String) -> Double? {
        events.append(.number(key)); return numbers[key]
    }
    func refreshRange() { events.append(.refresh); pipeline.refreshRange(for: self) }
    func logNumericPipeline(_ message: String, level: SkinLogLevel) {
        events.append(.log(level, message))
        let callback = onLog
        onLog = nil
        callback?()
    }
    func snapshot() -> SkinRuntimeState.MeasureState {
        pipeline.runtimeSnapshot(type: "numeric", kind: "IndependentNumericSource", own: IniSection(name: name),
                                 value: value, rawString: rawString, averageSize: averageSize)
    }
}

func runMeasureNumericSourceTests(_ t: TestRunner) {
    t.suite("Engine: measure numeric source: history placeholder inversion and seeding without a Skin") {
        let source = IndependentNumericSource()
        source.numbers = ["MinValue": 0, "MaxValue": 100]
        source.integers["AverageSize"] = 2
        source.booleans["InvertMeasure"] = true
        source.pipeline.readValueOptions(for: source)
        source.pipeline.finishValue(20, for: source)
        t.equal(source.value, 80)
        source.computedPlaceholder = true
        source.pipeline.finishValue(-1, for: source)
        t.equal(source.value, -1, "placeholder bypasses averaging, range observation and inversion")
        t.equal(source.snapshot().average, SkinRuntimeState.Average(samples: [20], next: 1))
        source.computedPlaceholder = false
        source.rawString = "sample"
        source.pipeline.finishValue(40, for: source)
        t.equal(source.value, 70)
        let state = source.snapshot()
        t.equal(state, SkinRuntimeState.MeasureState(type: "numeric", kind: "IndependentNumericSource",
            own: IniSection(name: "NumericSource"), value: 70, rawString: "sample",
            average: SkinRuntimeState.Average(samples: [20, 40], next: 0), observedMin: 20, observedMax: 30, webParser: nil))

        let successor = IndependentNumericSource()
        successor.numbers = source.numbers
        successor.integers = source.integers
        successor.booleans = source.booleans
        successor.pipeline.readValueOptions(for: successor)
        successor.pipeline.seed(state, for: successor)
        t.equal(successor.snapshot(), state)
        for raw in [60.0, .infinity] {
            source.pipeline.finishValue(raw, for: source)
            successor.pipeline.finishValue(raw, for: successor)
            t.equal(successor.snapshot(), source.snapshot(), "the resumed owner continues the same ring and range")
        }
        t.equal(successor.value, 70)
        t.equal(successor.snapshot().average, SkinRuntimeState.Average(samples: [60, 0], next: 0))
        t.equal(successor.snapshot().observedMin, 20)
        t.equal(successor.snapshot().observedMax, 50)
        successor.integers["AverageSize"] = 1
        successor.pipeline.readValueOptions(for: successor)
        t.equal(successor.snapshot().average, nil, "disabling the window discards its history")
        successor.pipeline.finishValue(25, for: successor)
        t.equal(successor.value, 75)
    }

    t.suite("Engine: measure numeric source: automatic bounds and gated options retain live read order") {
        let source = IndependentNumericSource()
        source.tracksValueRange = false
        source.lower = -2
        source.span = 12
        source.pipeline.readValueOptions(for: source)
        t.equal(source.events, [.number("MinValue"), .number("MaxValue"), .refresh, .minimum,
                                .maximum(afterMinimum: -2), .boolean("InvertMeasure"), .integer("AverageSize")])
        t.equal(source.minValue, -2); t.equal(source.maxValue, 10)
        source.events = []
        source.lower = 7
        source.pipeline.finishValue(7, for: source)
        t.equal(source.events, [.refresh, .minimum, .maximum(afterMinimum: 7)])
        t.equal(source.minValue, 7); t.equal(source.maxValue, 19)

        source.events = []
        source.rangeOptionScale = 2
        source.numbers = ["MinValue": 3, "MaxValue": 40]
        source.integers["AverageSize"] = 99_999
        source.pipeline.readValueOptions(for: source)
        t.equal(source.events, [.number("MinValue"), .number("MaxValue"), .refresh,
                                .boolean("InvertMeasure"), .integer("AverageSize")])
        t.equal(source.minValue, 6); t.equal(source.maxValue, 80)
        t.equal(source.averageSize, 10_000)

        source.events = []
        source.allowsMinValueOption = false; source.allowsMaxValueOption = false
        source.allowsInvert = false; source.allowsAverage = false
        source.pipeline.readValueOptions(for: source)
        t.equal(source.events, [.refresh, .minimum, .maximum(afterMinimum: 7)],
                "ignored options are never evaluated, and automatic bounds are restored")
        t.equal(source.averageSize, 1)
        t.check(!source.invert)
    }

    t.suite("Engine: measure numeric source: diagnostics may reenter and owners remain borrowed") {
        let pipeline = MeasurePipeline()
        var source: IndependentNumericSource? = IndependentNumericSource(pipeline: pipeline)
        weak var borrowed = source
        if let value = source {
            value.numbers = ["MinValue": 20, "MaxValue": 10]
            value.onLog = { pipeline.refreshRange(for: value) }
            pipeline.readValueOptions(for: value)
            t.equal(value.events, [.number("MinValue"), .number("MaxValue"), .refresh,
                                   .log(.debug, "[NumericSource] MaxValue is less than MinValue"),
                                   .boolean("InvertMeasure"), .integer("AverageSize")],
                    "the diagnostic is latched before its synchronous callback reenters range refresh")
            pipeline.finishValue(.nan, for: value)
            t.equal(value.value, 0)
        }
        source = nil
        t.check(borrowed == nil, "retaining the numerical pipeline does not retain its producer")
        withExtendedLifetime(pipeline) {}
    }
}
