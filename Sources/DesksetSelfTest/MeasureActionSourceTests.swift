import Foundation
@testable import DesksetCore

private final class ActionSourceTrace {
    var events: [String] = []
}

/// Values supplied by an owner at each read, without constructing a Skin, Measure or host. Formula and PCRE still
/// run in the production pipeline; this source does not implement another variable or action interpreter.
private final class IndependentActionSource: MeasureActionSource {
    let name = "Source"
    let trace: ActionSourceTrace
    var value: Double = 2
    var text = "waiting"
    var identifiers: [String: Double] = [:]
    var families: [String: [(index: Int, value: String)]] = [:]
    var actions: [String: String] = [:]
    var numbers: [String: Double] = [:]
    var modes: [String: Bool] = [:]
    var awaiting: Set<String> = []

    init(trace: ActionSourceTrace) { self.trace = trace }

    var stringValue: String {
        trace.events.append("string:\(text)")
        return text
    }

    func bool(_ key: String, _ defaultValue: Bool) -> Bool { modes[key] ?? defaultValue }
    func actionOption(_ key: String) -> String { actions[key] ?? "" }
    func optionalDouble(_ key: String) -> Double? { numbers[key] }
    func awaitsSectionVariables(_ key: String) -> Bool { awaiting.contains(key) }
    func numberedActionOptions(_ key: String) -> [(index: Int, value: String)] { families[key] ?? [] }

    func logActionPipeline(_ message: String, level: SkinLogLevel) {
        trace.events.append("log:\(level.rawValue):\(message)")
    }

    func actionFormulaValue(of identifier: String) -> Double? {
        trace.events.append("lookup:\(identifier)")
        return identifiers[identifier]
    }
}

func runMeasureActionSourceTests(_ t: TestRunner) {
    t.suite("Engine: measure action source: nested execution reads live values without a Skin") {
        let trace = ActionSourceTrace()
        let source = IndependentActionSource(trace: trace)
        let pipeline = MeasurePipeline()
        source.identifiers = ["First": 1, "Second": 0]
        source.families = ["IfCondition": [(1, "First"), (2, "Second")], "IfMatch": [(1, "ready")]]
        source.numbers = ["IfAboveValue": 10]
        source.actions = ["IfTrueAction": "first", "IfTrueAction2": "second", "IfAboveAction": "above",
                          "IfMatchAction": "match", "IfNotMatchAction": "miss",
                          "OnChangeAction": "change", "OnUpdateAction": "update"]
        pipeline.readOptions(for: source)

        func execute(_ action: String) {
            trace.events.append("action:\(action)")
            switch action {
            case "first":
                source.identifiers["Second"] = 1
                source.value = 20
                pipeline.run(for: source, execute: execute)
            case "second": source.value = 30
            case "above": source.value = 5; source.text = "ready"
            case "change": source.value = 9
            default: break
            }
        }

        pipeline.run(for: source, execute: execute)
        t.equal(trace.events, [
            "lookup:First", "action:first", "lookup:First", "lookup:Second", "action:second",
            "action:above", "string:ready", "action:match", "action:update",
            "lookup:Second", "string:ready", "action:update",
        ], "the nested run sees the committed first edge; later formulas and text see synchronous effects")
        t.equal(source.value, 5)

        trace.events = []
        source.value = 20
        source.text = "waiting"
        pipeline.run(for: source, execute: execute)
        t.equal(trace.events, ["lookup:First", "lookup:Second", "action:above", "string:ready", "action:update"],
                "the outer first run rearmed the threshold after the nested action lowered the value")

        trace.events = []
        source.value = 6
        source.text = "later"
        pipeline.run(for: source, execute: execute)
        t.equal(trace.events, ["lookup:First", "lookup:Second", "string:later", "action:miss",
                               "action:change", "action:update"])
        t.equal(source.value, 9, "OnChange changed the value before its comparison baseline was stored")
        trace.events = []
        pipeline.run(for: source, execute: execute)
        t.equal(trace.events, ["lookup:First", "lookup:Second", "string:later", "action:update"],
                "the next run does not invent a second change from the callback's value")
    }

    t.suite("Engine: measure action source: lazy reads, diagnostics and borrowed lifetime") {
        let trace = ActionSourceTrace()
        let source = IndependentActionSource(trace: trace)
        let pipeline = MeasurePipeline()
        source.actions = ["OnUpdateAction": "update"]
        pipeline.readOptions(for: source)
        pipeline.run(for: source) { trace.events.append("action:\($0)") }
        t.equal(trace.events, ["action:update"], "without matches or OnChange, stringValue is not asked for")

        trace.events = []
        source.families = ["IfCondition": [(1, "(")]]
        source.awaiting = ["IfCondition"]
        pipeline.readOptions(for: source)
        t.equal(trace.events, [], "an unresolved section-variable read defers a compile diagnostic")
        source.awaiting = []
        pipeline.readOptions(for: source)
        t.equal(trace.events, ["log:Error:[Source] invalid IfCondition: ("])
        trace.events = []
        pipeline.readOptions(for: source)
        pipeline.run(for: source) { trace.events.append("action:\($0)") }
        t.equal(trace.events, ["action:update"], "the compile diagnostic is still once per condition")

        let errors = MeasurePipeline()
        source.families = ["IfCondition": [(1, "Missing")], "IfMatch": [(1, "[")]]
        errors.readOptions(for: source)
        trace.events = []
        errors.run(for: source) { trace.events.append("action:\($0)") }
        t.equal(trace.events, ["lookup:Missing", "log:Error:[Source] cannot evaluate IfCondition: Missing",
                               "string:waiting", "log:Error:[Source] invalid IfMatch pattern: [", "action:update"])
        trace.events = []
        errors.run(for: source) { trace.events.append("action:\($0)") }
        t.equal(trace.events, ["lookup:Missing", "string:waiting", "action:update"],
                "failed lookups still occur on later runs, while each diagnostic remains once")

        let keptPipeline = MeasurePipeline()
        weak var borrowed: IndependentActionSource?
        do {
            let temporary = IndependentActionSource(trace: trace)
            temporary.identifiers = ["Observed": 1]
            temporary.families = ["IfCondition": [(1, "Observed")]]
            temporary.actions = ["IfTrueAction": "touch"]
            borrowed = temporary
            keptPipeline.readOptions(for: temporary)
            keptPipeline.run(for: temporary) { _ in temporary.value = 17 }
            t.equal(temporary.value, 17, "the non-escaping action really ran against the borrowed source")
        }
        withExtendedLifetime(keptPipeline) {
            t.check(borrowed == nil, "compiled conditions and the kept pipeline retain neither source nor callback")
        }
    }
}
