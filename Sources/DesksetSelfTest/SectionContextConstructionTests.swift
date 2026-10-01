import Foundation
@testable import DesksetCore

private enum SectionConstructionError: Error { case utcUnavailable }

private final class SectionConstructionSystem: FakeSystem {
    private(set) var processors: [Int] = []

    override func cpuUsage(processor: Int) -> Double {
        processors.append(processor)
        return cpu
    }
}

/// A test owner of real measure kernels, with no Skin or closures that capture one. Unsupported service paths
/// fail if called: this fixture qualifies String and CPU, rather than pretending to implement another runtime.
private final class IndependentSectionContext: SectionContext {
    var settings = SkinSettings()
    var sources = IniSourceMap()
    var optionsLoaded = false
    let runsInVirtualTime = true
    var measureValues: MeasureValueOverride?
    weak var host: SkinHost?
    let system: SystemDataSource
    var counter = 0
    let random = SkinRandom(seed: 1)
    let skinClock: SkinClock
    let clock: () -> TimeInterval = { 86_400 }
    let executor: SkinExecutor
    let locale = Locale(identifier: "en_US_POSIX")
    let directory: URL
    let sideEffects: SideEffects
    var styles: [String: IniSection] = [:]
    var variables: [String: String] = [:]
    var measures: [String: Measure] = [:]
    private(set) var services: [BackgroundWorkKind] = []
    private(set) var actions: [Bang] = []
    private(set) var logs: [String] = []
    private var logged: Set<String> = []
    private var issues: Set<String> = []
    private var snapshotChanges = 0

    init(directory: URL, system: SystemDataSource = SectionConstructionSystem()) throws {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw SectionConstructionError.utcUnavailable }
        let date = Date(timeIntervalSince1970: 1_798_761_598)
        self.directory = directory
        self.system = system
        skinClock = .fixed(date, timeZone: utc)
        executor = VirtualTimeExecutor(start: date, timeZone: utc)
        sideEffects = RecordingSideEffects(directory: directory.appendingPathComponent("effects"))
    }

    func styleSection(named name: String) -> IniSection? { styles[name.lowercased()] }
    func styleValues(named name: String) -> [String: String]? {
        styleSection(named: name).map { OptionStack.index($0) }
    }

    private func resolver(in section: SkinSection?, sectionVariables: Bool) -> VariableResolver {
        VariableResolver(variableLookup: { [unowned self] name in
            name.lowercased() == "currentsection" ? section?.name : self.variables[name.lowercased()]
        }, sectionLookup: sectionVariables ? { [unowned self] name, parameter in
            guard let measure = self.measures[name.lowercased()] else { return nil }
            switch parameter {
            case .none: return measure.stringValue
            case .number(let format):
                return format.format(value: measure.value, minValue: measure.minValue, maxValue: measure.maxValue)
            case .keyword: preconditionFailure("Unqualified section variable keyword in the construction fixture")
            }
        } : nil)
    }

    func resolve(_ text: String, in section: SkinSection?, sectionVariables: Bool) -> String {
        resolver(in: section, sectionVariables: sectionVariables).resolve(text)
    }
    func resolveStandardVariables(_ text: String, in section: SkinSection?) -> String {
        resolver(in: section, sectionVariables: false).resolveStandardVariables(text)
    }
    func mentionsSectionVariable(_ text: String) -> Bool {
        var found = false
        let detector = VariableResolver(variableLookup: { _ in nil }, sectionLookup: { [unowned self] name, _ in
            if self.measures[name.lowercased()] != nil { found = true }
            return nil
        })
        _ = detector.resolve(text)
        return found
    }

    func noteSnapshotChange() { snapshotChanges += 1 }
    func assertOwned(_ entry: StaticString) { precondition(executor.isCurrent, "\(entry) called off the fixture owner") }
    func log(_ message: String, level: SkinLogLevel) { logs.append("\(level.rawValue): \(message)") }
    func logOnce(_ message: String, level: SkinLogLevel) {
        if logged.insert(message).inserted { log(message, level: level) }
    }
    func addIssue(_ issue: String) { issues.insert(issue) }
    func removeIssue(_ issue: String) { issues.remove(issue) }
    func currentEnvironment() -> SkinEnvironment { SkinEnvironment(locale: locale) }
    func readablePath(_ path: String) -> String { path }
    func formulaValue(of identifier: String, from section: SkinSection?) -> Double? {
        measures[identifier.lowercased()]?.value
    }
    func noteService(_ kind: BackgroundWorkKind) { services.append(kind) }

    /// Only these two synthetic canaries are accepted. Parsing/variable expansion reuse the real components;
    /// this is a synchronous pipeline observation, not a replacement for Skin's general action executor.
    func execute(_ actionText: String, from section: SkinSection?) {
        assertOwned(#function)
        for action in ActionParser.parse(resolve(actionText, in: section, sectionVariables: true)) {
            guard case .bang(let bang) = action else { preconditionFailure("Unexpected external action") }
            actions.append(bang)
            switch bang.name {
            case "canary":
                precondition(bang.args == ["7"] && measures["state"] != nil)
                measures["state"]?.value = 7
                variables["state"] = "7"
            case "log":
                precondition(bang.args.count == 1)
                log(bang.args[0], level: .notice)
            default: preconditionFailure("Unexpected construction fixture action")
            }
        }
    }
    func executePointerAction(_ action: String, from section: SkinSection, x: Double, y: Double,
                              relativeToSkin: Bool) { preconditionFailure("Unexpected pointer action") }
    func async(_ work: @escaping () -> Void) { preconditionFailure("Unexpected asynchronous measure work") }
    func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void,
                            orElse dropped: ((T) -> Void)?) { preconditionFailure("Unexpected background measure work") }
}

private func constructionSection(_ name: String, _ options: [(String, String)]) -> IniSection {
    IniSection(name: name, entries: options.map { IniEntry(key: $0.0, value: $0.1) })
}

func runSectionContextConstructionTests(_ t: TestRunner) {
    t.suite("Engine: section context construction: String options and actions use an independent owner") {
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("section-construction-string"))
        context.settings.defaultUpdateDivider = 3
        context.variables = ["prefix": "first", "state": "0"]
        context.styles = [
            "early": constructionSection("Early", [("Tag", "early"), ("OnlyEmpty", ""), ("ValueReminder", "9")]),
            "late": constructionSection("Late", [("Tag", ""), ("OnlyEmpty", "")]),
        ]
        let input = StringMeasure(name: "Input", section: constructionSection("Input", [("String", "4")]),
                                  context: context, type: "string")
        context.measures["input"] = input
        input.readOptionsIfNeeded()
        input.performUpdate()
        t.equal(input.stringValue, "4")
        t.equal(input.value, 4)

        let reader = StringMeasure(name: "Reader", section: constructionSection("Reader", [
            ("String", "#Prefix# [Input] #CURRENTSECTION#"), ("Tag", ""),
        ]), context: context, type: "string")
        context.measures["reader"] = reader
        reader.styles = ["Early", "Late"]
        let file = context.directory.appendingPathComponent("synthetic.ini")
        let own = IniSourceLocation(file: file, line: 5), late = IniSourceLocation(file: file, line: 9)
        context.sources.options = ["reader": ["tag": own], "late": ["tag": late]]
        t.equal(reader.rawOption("TAG"), "early")
        t.equal(reader.fileOption("Tag"), "early")
        t.equal(reader.styleFileOption("Tag"), "early")
        t.equal(reader.fileOrigin("Tag"), .own(own))
        t.equal(reader.optionOrigin("Tag"), .own(own))
        t.equal(reader.rawOption("OnlyEmpty"), "")
        t.equal(reader.rawOption("Missing"), nil)
        t.equal(reader.rawOption("ValueRemainder"), "9")
        t.equal(reader.fileOption("ValueRemainder"), nil)
        reader.overrides["tag"] = "runtime"
        t.equal(reader.rawOption("Tag"), "runtime")
        t.equal(reader.optionOrigin("Tag"), .setOption)
        t.equal(reader.fileOption("Tag"), "early")
        reader.overrides["tag"] = ""
        t.equal(reader.rawOption("Tag"), "early")
        t.equal(reader.optionOrigin("Tag"), .style("Late", late))
        t.equal(reader.fileOrigin("Tag"), .own(own))

        reader.readOptionsIfNeeded()
        reader.performUpdate()
        t.equal(reader.updateDivider, 3)
        t.equal(reader.stringValue, "first [Input] Reader", "load-time non-dynamic read preserves section syntax")
        t.check(reader.mentionsSectionVariables)
        context.optionsLoaded = true
        reader.needsOptionRead = true
        reader.readOptionsIfNeeded()
        reader.performUpdate()
        t.equal(reader.stringValue, "first 4 Reader")
        context.variables["prefix"] = "second"
        input.overrides["string"] = "8"
        input.needsOptionRead = true
        input.readOptionsIfNeeded()
        input.performUpdate()
        reader.readOptionsIfNeeded()
        reader.performUpdate()
        t.equal(reader.stringValue, "first 4 Reader", "a non-dynamic option retains the preceding read")
        reader.overrides["dynamicvariables"] = "1"
        reader.needsOptionRead = true
        reader.readOptionsIfNeeded()
        reader.performUpdate()
        t.equal(reader.stringValue, "second 8 Reader")
        context.variables["prefix"] = "third"
        reader.readOptionsIfNeeded()
        reader.performUpdate()
        t.equal(reader.stringValue, "third 8 Reader")

        let state = StringMeasure(name: "State", section: constructionSection("State", [("String", "0")]),
                                  context: context, type: "string")
        context.measures["state"] = state
        state.readOptionsIfNeeded()
        state.performUpdate()
        let gate = StringMeasure(name: "Gate", section: constructionSection("Gate", [
            ("String", "1"), ("IfCondition", "1"), ("IfTrueAction", "[!Canary 7]"),
            ("IfCondition2", "State=7"), ("IfTrueAction2", "[!Log next:[#State]]"),
            ("IfFalseAction2", "[!Log unexpected-stale]"),
            ("OnUpdateAction", "[!Log \"frozen:#State#;live:[#State]\"]"),
        ]), context: context, type: "string")
        context.measures["gate"] = gate
        gate.readOptionsIfNeeded()
        gate.performUpdate()
        t.equal(gate.value, 1)
        t.equal(state.value, 7, "the first synchronous action changes an actual independent measure")
        t.equal(context.actions, [Bang(name: "canary", args: ["7"]), Bang(name: "log", args: ["next:7"]),
                                  Bang(name: "log", args: ["frozen:0;live:7"])])
        t.equal(context.logs, ["Notice: next:7", "Notice: frozen:0;live:7"])
        t.equal(context.services, [], "String performs no live service reads")
        t.check(context.executor.isCurrent)
    }

    t.suite("Engine: section context construction: CPU sampling and pinned history use an independent owner") {
        let system = SectionConstructionSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("section-construction-cpu"), system: system)
        context.optionsLoaded = true
        let cpu = CPUMeasure(name: "CPU", section: constructionSection("CPU", [
            ("Processor", "2"), ("AverageSize", "2"), ("InvertMeasure", "1"), ("MinValue", "0"),
            ("MaxValue", "100"), ("OnUpdateAction", "[!Log \"cpu:[CPU:]\"]"),
        ]), context: context, type: "cpu")
        context.measures["cpu"] = cpu
        cpu.readOptionsIfNeeded()
        cpu.setPaused(true)
        cpu.performUpdate()
        t.equal(system.processors, [])
        t.equal(context.services, [], "a paused first update does not mark or read live inputs")
        t.equal(cpu.updateCount, 0)
        cpu.setPaused(false)
        cpu.readOptionsIfNeeded()
        var reads: [Int] = []
        system.cpu = 20
        cpu.performUpdate()
        reads.append(system.processors.count)
        t.equal(cpu.value, 80)
        t.equal(system.processors, [2])
        let sample = MeasureValueOverride()
        sample.pinned["cpu"] = (value: 90, text: nil)
        context.measureValues = sample
        system.cpu = 97
        cpu.performUpdate()
        reads.append(system.processors.count)
        t.equal(cpu.value, 90)
        t.equal(system.processors, [2])
        sample.pinned.removeAll()
        system.cpu = 40
        cpu.performUpdate()
        reads.append(system.processors.count)
        t.equal(cpu.value, 70)
        t.equal(system.processors, [2, 2])
        t.equal(reads, [1, 1, 2], "the pinned update bypasses actual CPU sampling")
        t.equal(cpu.minValue, 0)
        t.equal(cpu.maxValue, 100)
        t.equal(cpu.updateCount, 3)
        t.equal(context.services, [.system])
        t.equal(context.logs, ["Notice: cpu:80", "Notice: cpu:90", "Notice: cpu:70"])
        t.equal(cpu.runtimeSnapshot.average, SkinRuntimeState.Average(samples: [20, 40], next: 0))
        cpu.setPaused(true)
        cpu.performUpdate()
        t.equal(cpu.value, 70)
        t.equal(cpu.updateCount, 3)
        cpu.setPaused(false)
        cpu.setDisabled(true)
        cpu.performUpdate()
        t.equal(cpu.value, 0)
        t.equal(cpu.updateCount, 3)
        t.equal(system.processors, [2, 2], "paused and disabled updates never read CPU")
        t.equal(context.services, [.system])
        t.equal(context.logs.count, 3)
    }

    t.suite("Engine: section context construction: legacy Skin identity and borrowed lifetimes remain intact") {
        let system = SectionConstructionSystem()
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Update=-1
        [Text]
        Measure=String
        String=legacy
        [CPU]
        Measure=CPU
        Processor=2
        AverageSize=2
        InvertMeasure=1
        MinValue=0
        MaxValue=100
        """, system: system)
        defer { skin.close() }
        guard let text = skin.measure(named: "Text") as? StringMeasure,
              let cpu = skin.measure(named: "CPU") as? CPUMeasure else { return t.check(false, "legacy factory classes") }
        t.check(text.skin === skin)
        t.check(cpu.skin === skin)
        system.cpu = 20
        skin.update()
        t.equal(text.stringValue, "legacy")
        t.equal(cpu.value, 80)
        let sample = MeasureValueOverride()
        sample.pinned["cpu"] = (value: 90, text: nil)
        skin.measureValues = sample
        skin.update()
        t.equal(cpu.value, 90)
        sample.pinned.removeAll()
        system.cpu = 40
        skin.update()
        t.equal(cpu.value, 70)
        t.equal(system.processors, [2, 2])
        let direct = StringMeasure(name: "Direct", section: constructionSection("Direct", [("String", "direct")]),
                                   skin: skin, type: "string")
        direct.readOptionsIfNeeded()
        direct.performUpdate()
        t.check(direct.skin === skin, "the original public required initializer keeps exact identity")
        t.equal(direct.stringValue, "direct")

        var context: IndependentSectionContext? = try IndependentSectionContext(directory: t.temporaryDirectory("section-construction-lifetime"))
        weak var borrowedContext = context
        let kernel = StringMeasure(name: "Borrowed", section: constructionSection("Borrowed", [("String", "independent")]),
                                   context: context!, type: "string")
        context?.measures["borrowed"] = kernel
        var host: FakeHost? = FakeHost()
        weak var borrowedHost = host
        context?.host = host
        t.check(kernel.serviceHost === host)
        host = nil
        t.check(borrowedHost == nil)
        t.check(kernel.serviceHost == nil, "host service reads follow the weak live channel")
        kernel.readOptionsIfNeeded()
        kernel.performUpdate()
        t.equal(kernel.stringValue, "independent")
        context = nil
        t.check(borrowedContext == nil, "a retained kernel never retains its independent context")
        withExtendedLifetime(kernel) {} // No access through the borrowed reference after its owner was released.
    }
}
