import Foundation
@testable import DesksetCore

private enum LocalLoweringEvent: Equatable {
    case local(ResolvedLocalAction)
    case host(Bang)
    case forward(owner: String, closed: Bool, Bang, String)
}

private final class LocalLoweringTrace {
    var events: [LocalLoweringEvent] = []
}

/// A target with no Skin/section dependency; its local callback can synchronously change the forwarding owner.
private final class LocalLoweringTarget: ActionTarget {
    let config = "Root\\Sub"
    let trace: LocalLoweringTrace
    var reenterOnUpdate = false
    private var owner = "first"
    private var closed = false

    init(trace: LocalLoweringTrace) { self.trace = trace }

    func performLocalAction(_ action: ResolvedLocalAction) {
        trace.events.append(.local(action))
        if action == .update && reenterOnUpdate {
            reenterOnUpdate = false
            ActionExecutor.perform(Bang(name: "log", args: ["nested", "debug"]), literalArguments: [], on: self)
            owner = "second"
            closed = true
        }
    }

    func handleHostAction(_ bang: Bang) { trace.events.append(.host(bang)) }

    func forwardAction(_ bang: Bang, toConfig config: String) {
        trace.events.append(.forward(owner: owner, closed: closed, bang, config))
    }
}

func runActionLoweringTests(_ t: TestRunner) {
    t.suite("Action: local lowering: named operands cover the local catalog and retain literal syntax") {
        func value(_ text: String, literal: Bool = false) -> ActionValue {
            ActionValue(text: text, isLiteral: literal)
        }
        // Expected operands come from the bang contracts, independently of the catalog descriptors. In
        // particular, mouse groups reverse the target/list positions and coordinates must remain raw text.
        let examples: [(Bang, ResolvedLocalAction)] = [
            (Bang(name: "setoption", args: ["Box", "W", "(Reading*2)"]),
             .setOption(target: .name("Box"), key: "W", value: value("(Reading*2)"))),
            (Bang(name: "setoptiongroup", args: ["Panels", "H", "(Reading*3)"]),
             .setOption(target: .group("Panels"), key: "H", value: value("(Reading*3)"))),
            (Bang(name: "setvariable", args: ["V", "(1+2)"]), .setVariable(name: "V", value: value("(1+2)"))),
            (Bang(name: "writekeyvalue", args: ["Variables", "V", "(1+3)", "settings.ini"]),
             .writeKeyValue(section: "Variables", key: "V", value: value("(1+3)"), file: "settings.ini")),
            (Bang(name: "update", args: []), .update),
            (Bang(name: "redraw", args: []), .redraw),
            (Bang(name: "updatemeter", args: [" * "]), .updateMeter(.name(" * "))),
            (Bang(name: "updatemetergroup", args: ["Panels"]), .updateMeter(.group("Panels"))),
            (Bang(name: "updatemeasure", args: ["Reading"]), .updateMeasure(.name("Reading"))),
            (Bang(name: "updatemeasuregroup", args: ["Samples"]), .updateMeasure(.group("Samples"))),
            (Bang(name: "movemeter", args: [" (Reading+1)r ", " -2R ", "Box"]),
             .moveMeter(name: "Box", x: " (Reading+1)r ", y: " -2R ")),
            (Bang(name: "showmeter", args: ["Box"]), .meterHidden(.set(false), target: .name("Box"))),
            (Bang(name: "hidemeter", args: ["Box"]), .meterHidden(.set(true), target: .name("Box"))),
            (Bang(name: "togglemeter", args: ["Box"]), .meterHidden(.toggle, target: .name("Box"))),
            (Bang(name: "showmetergroup", args: ["Panels"]), .meterHidden(.set(false), target: .group("Panels"))),
            (Bang(name: "hidemetergroup", args: ["Panels"]), .meterHidden(.set(true), target: .group("Panels"))),
            (Bang(name: "togglemetergroup", args: ["Panels"]), .meterHidden(.toggle, target: .group("Panels"))),
            (Bang(name: "enablemeasure", args: ["Reading"]), .measureDisabled(.set(false), target: .name("Reading"))),
            (Bang(name: "disablemeasure", args: ["Reading"]), .measureDisabled(.set(true), target: .name("Reading"))),
            (Bang(name: "togglemeasure", args: ["Reading"]), .measureDisabled(.toggle, target: .name("Reading"))),
            (Bang(name: "enablemeasuregroup", args: ["Samples"]),
             .measureDisabled(.set(false), target: .group("Samples"))),
            (Bang(name: "disablemeasuregroup", args: ["Samples"]),
             .measureDisabled(.set(true), target: .group("Samples"))),
            (Bang(name: "togglemeasuregroup", args: ["Samples"]), .measureDisabled(.toggle, target: .group("Samples"))),
            (Bang(name: "pausemeasure", args: ["Reading"]), .measurePaused(.set(true), target: .name("Reading"))),
            (Bang(name: "unpausemeasure", args: ["Reading"]), .measurePaused(.set(false), target: .name("Reading"))),
            (Bang(name: "togglepausemeasure", args: ["Reading"]), .measurePaused(.toggle, target: .name("Reading"))),
            (Bang(name: "pausemeasuregroup", args: ["Samples"]), .measurePaused(.set(true), target: .group("Samples"))),
            (Bang(name: "unpausemeasuregroup", args: ["Samples"]),
             .measurePaused(.set(false), target: .group("Samples"))),
            (Bang(name: "togglepausemeasuregroup", args: ["Samples"]), .measurePaused(.toggle, target: .group("Samples"))),
            (Bang(name: "commandmeasure", args: ["Script", "Run(1)"]), .commandMeasure(name: "Script", command: "Run(1)")),
            (Bang(name: "pluginbang", args: ["Script", "Run(2)"]), .commandMeasure(name: "Script", command: "Run(2)")),
            (Bang(name: "disablemouseaction", args: ["Box", "LeftMouseUpAction"]),
             .mouseAction(.disable, target: .name("Box"), actions: "LeftMouseUpAction")),
            (Bang(name: "clearmouseaction", args: ["Box", "LeftMouseUpAction"]),
             .mouseAction(.clear, target: .name("Box"), actions: "LeftMouseUpAction")),
            (Bang(name: "enablemouseaction", args: ["Rainmeter", "LeftMouseUpAction"]),
             .mouseAction(.enable, target: .name("Rainmeter"), actions: "LeftMouseUpAction")),
            (Bang(name: "togglemouseaction", args: ["*", "LeftMouseUpAction"]),
             .mouseAction(.toggle, target: .name("*"), actions: "LeftMouseUpAction")),
            (Bang(name: "disablemouseactiongroup", args: ["LeftMouseUpAction", "Panels"]),
             .mouseAction(.disable, target: .group("Panels"), actions: "LeftMouseUpAction")),
            (Bang(name: "clearmouseactiongroup", args: ["LeftMouseUpAction", "Panels"]),
             .mouseAction(.clear, target: .group("Panels"), actions: "LeftMouseUpAction")),
            (Bang(name: "enablemouseactiongroup", args: ["LeftMouseUpAction", "Panels"]),
             .mouseAction(.enable, target: .group("Panels"), actions: "LeftMouseUpAction")),
            (Bang(name: "togglemouseactiongroup", args: ["LeftMouseUpAction", "Panels"]),
             .mouseAction(.toggle, target: .group("Panels"), actions: "LeftMouseUpAction")),
            (Bang(name: "log", args: ["message", " WaRnInG "]), .log(message: "message", level: .warning)),
        ]
        let exercised = Set(examples.map { $0.0.name })
        let catalogLocal = Set(ActionCatalog.all.filter { $0.handler == .engineLocal }.map(\.name))
        t.equal(exercised.count, 40, "the complete local command contract is exercised")
        t.equal(catalogLocal.subtracting(exercised), [], "no untested local descriptor")
        t.equal(exercised.subtracting(catalogLocal), [], "no invented local command")
        t.check(exercised.isSubset(of: Set(BangCatalog.all.map(\.name))), "examples belong to the documented directory")
        for (bang, expected) in examples {
            t.equal(ActionExecutor.route(bang, currentConfig: "Root\\Sub", literalArguments: []), .local(expected), bang.name)
        }
        t.equal(ActionExecutor.route(Bang(name: "setoption", args: ["Box", "W", "(Reading*2)", "Root/Sub"]),
                                     currentConfig: "Root\\Sub", literalArguments: [2]),
                .local(.setOption(target: .name("Box"), key: "W", value: value("(Reading*2)", literal: true))))
        t.equal(ActionExecutor.route(Bang(name: "setvariable", args: ["V", "(1+2)"]),
                                     currentConfig: "Root\\Sub", literalArguments: [1]),
                .local(.setVariable(name: "V", value: value("(1+2)", literal: true))))
        t.equal(ActionExecutor.route(Bang(name: "writekeyvalue", args: ["Variables", "V", "(1+3)"]),
                                     currentConfig: "Root\\Sub", literalArguments: [2]),
                .local(.writeKeyValue(section: "Variables", key: "V", value: value("(1+3)", literal: true), file: "")))
        t.equal(ActionExecutor.route(Bang(name: "pluginbang", args: [" Script Command with spaces "]),
                                     currentConfig: "Root\\Sub", literalArguments: []),
                .local(.commandMeasure(name: "Script", command: "Command with spaces")))
        t.equal(ActionExecutor.route(Bang(name: "pluginbang", args: []),
                                     currentConfig: "Root\\Sub", literalArguments: []),
                .local(.commandMeasure(name: "", command: "")))
        t.equal(ActionExecutor.route(Bang(name: "setoption", args: []),
                                     currentConfig: "Root\\Sub", literalArguments: []),
                .local(.setOption(target: .name(""), key: "", value: value(""))), "missing operands stay empty")
        let remote = Bang(name: "movemeter", args: [" (Reading+1)r ", " -2R ", "Box", " /Other/ ", "discarded"])
        t.equal(ActionExecutor.route(remote, currentConfig: "Root\\Sub", literalArguments: []),
                .forward(Bang(name: "movemeter", args: [" (Reading+1)r ", " -2R ", "Box"]), toConfig: "Other"),
                "remote commands retain their original raw operands")
        let direct = Bang(name: "SetOption", args: ["Box", "W", "7", "*"])
        t.equal(ActionExecutor.route(direct, currentConfig: "Root\\Sub", literalArguments: []), .host(direct))
    }

    t.suite("Action: local lowering: the executor borrows a non-Skin target and forwards after local reentry") {
        let trace = LocalLoweringTrace()
        var owner: LocalLoweringTarget? = LocalLoweringTarget(trace: trace)
        weak var releasedOwner = owner
        if let target = owner {
            target.reenterOnUpdate = true
            ActionExecutor.perform(Bang(name: "update", args: ["*"]), literalArguments: [], on: target)
            t.equal(trace.events, [
                .local(.update), .local(.log(message: "nested", level: .debug)),
                .forward(owner: "second", closed: true, Bang(name: "update", args: []), "*"),
            ], "nested local execution finishes before forwarding through the target's current owner")
            let forwarded = Bang(name: "setvariable", args: ["Remote", "(1+2)", " /Elsewhere/ "])
            ActionExecutor.perform(forwarded, literalArguments: [1], on: target)
            let handled = [Bang(name: "execute", args: ["raw"]), Bang(name: "resetstats", args: ["raw"]),
                           Bang(name: "unknownbang", args: ["raw"]), Bang(name: "Delay", args: ["0"])]
            for bang in handled { ActionExecutor.perform(bang, literalArguments: [], on: target) }
            ActionExecutor.perform(Bang(name: "delay", args: ["0"]), literalArguments: [], on: target)
            t.equal(Array(trace.events.dropFirst(3)), [
                .forward(owner: "second", closed: true, Bang(name: "setvariable", args: ["Remote", "(1+2)"]), "Elsewhere"),
            ] + handled.map { .host($0) }, "host routing, unsupported requests and direct Delay stay distinct")
        }
        owner = nil
        t.check(releasedOwner == nil, "the executor and recorded pure values do not retain the borrowed target")
        t.equal(trace.events.count, 8, "observations remain available after the live target is released")
    }
}
