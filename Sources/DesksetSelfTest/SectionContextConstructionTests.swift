import Foundation
@testable import DesksetCore

private enum SectionConstructionError: Error { case utcUnavailable, unexpectedKernel }

private final class SectionConstructionSystem: FakeSystem {
    private(set) var processors: [Int] = []
    private(set) var memoryReads = 0
    private(set) var requestedInterfaces: [String?] = []
    var interfaces = ["en0", "en1"]
    var counters: [String: NetworkCounters] = [
        "en0": NetworkCounters(received: 1000, sent: 500),
        "en1": NetworkCounters(received: 100, sent: 50),
    ]

    override func cpuUsage(processor: Int) -> Double {
        processors.append(processor)
        return cpu
    }

    override func memoryStatus() -> MemoryStatus {
        memoryReads += 1
        return memory
    }

    override func networkInterfaces() -> [String] { interfaces }

    override func networkCounters(interface: String?) -> NetworkCounters {
        requestedInterfaces.append(interface)
        if let interface { return counters[interface] ?? NetworkCounters() }
        return counters.values.reduce(NetworkCounters()) {
            let received = $0.received.addingReportingOverflow($1.received)
            let sent = $0.sent.addingReportingOverflow($1.sent)
            precondition(!received.overflow && !sent.overflow, "Synthetic counters must fit UInt64")
            return NetworkCounters(received: received.partialValue, sent: sent.partialValue)
        }
    }
}

/// A test owner of real measure kernels, with no Skin or closures that capture one. Unsupported service paths
/// fail if called: this fixture qualifies selected built-ins, rather than pretending to implement another runtime.
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
    let clock: () -> TimeInterval
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

    init(directory: URL, system: SystemDataSource = SectionConstructionSystem(),
         clock: @escaping () -> TimeInterval = { 86_400 }) throws {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw SectionConstructionError.utcUnavailable }
        let date = Date(timeIntervalSince1970: 1_798_761_598)
        self.directory = directory
        self.system = system
        self.clock = clock
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
    runContextBuiltinFactoryTests(t)
}

private class ContextFactoryOverride: Measure {
    var constructorTrace: [String] = []

    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        constructorTrace.append("base:\(type)")
    }

    public override func computeValue() -> Double { 123 }
}

private final class ContextFactoryChild: ContextFactoryOverride {
    public required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
        constructorTrace.append("child:\(type)")
    }

    public override func computeValue() -> Double { 456 }
}

private func runContextBuiltinFactoryTests(_ t: TestRunner) {
    t.suite("Engine: context builtin factory: independent memory kinds preserve option and sample order") {
        let system = SectionConstructionSystem()
        system.memory = MemoryStatus(physicalTotal: 100, physicalUsed: 40, swapTotal: 20, swapUsed: 5)
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-memory"), system: system)
        context.optionsLoaded = true
        let cases: [(type: String, options: [(String, String)], value: Double, maximum: Double)] = [
            ("physicalmemory", [], 40, 100), ("swapmemory", [], 45, 120), ("memory", [], 85, 220),
            ("physicalmemory", [("Total", "1")], 100, 100), ("swapmemory", [("Total", "1")], 120, 120),
            ("memory", [("Total", "1")], 220, 220), ("physicalmemory", [("Free", "1")], 60, 100),
            ("memory", [("InvertMeasure", "1")], 135, 220),
        ]
        for (index, item) in cases.enumerated() {
            let name = "Memory\(index)"
            let before = system.memoryReads
            guard let measure = makeContextBuiltinMeasure(MemoryMeasure.self, name: name,
                section: constructionSection(name, item.options + [("MaxValue", "5")]),
                context: context, type: item.type) as? MemoryMeasure else { throw SectionConstructionError.unexpectedKernel }
            context.measures[name.lowercased()] = measure
            t.equal(system.memoryReads, before, "constructing a kind never samples memory")
            t.equal(measure.type, item.type)
            measure.readOptionsIfNeeded()
            t.equal(system.memoryReads, before + 1, "the original automatic maximum samples at option read")
            t.equal(measure.maxValue, item.maximum, "MaxValue is ignored for every memory kind")
            measure.performUpdate()
            t.equal(system.memoryReads, before + 2)
            t.equal(measure.value, item.value)
            t.equal(measure.automaticMaxValue, item.maximum)
            t.equal(system.memoryReads, before + 2, "the sampled total is cached before numeric range refresh")
        }
        t.equal(context.services, Array(repeating: .system, count: cases.count))
        t.equal(context.logs, [])

        var owner: IndependentSectionContext? = try IndependentSectionContext(directory: t.temporaryDirectory("context-memory-lifetime"))
        weak var borrowed = owner
        guard let kernel = makeContextBuiltinMeasure(MemoryMeasure.self, name: "BorrowedMemory",
            section: constructionSection("BorrowedMemory", []), context: owner!, type: "memory") else {
            throw SectionConstructionError.unexpectedKernel
        }
        owner?.measures["borrowedmemory"] = kernel
        owner = nil
        t.check(borrowed == nil, "the context factory does not retain a memory kernel's owner")
        withExtendedLifetime(kernel) {}
    }

    t.suite("Engine: context builtin factory: independent network directions retain rates and per-node history") {
        let system = SectionConstructionSystem()
        var now = 100.0
        var clockReads = 0
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-network"), system: system,
                                                   clock: { clockReads += 1; return now })
        context.optionsLoaded = true
        func node(_ name: String, _ type: String, _ options: [(String, String)] = []) throws -> NetMeasure {
            guard let measure = makeContextBuiltinMeasure(NetMeasure.self, name: name,
                section: constructionSection(name, options), context: context, type: type) as? NetMeasure else {
                throw SectionConstructionError.unexpectedKernel
            }
            context.measures[name.lowercased()] = measure
            measure.readOptionsIfNeeded()
            return measure
        }
        let incoming = try node("Incoming", "netin", [("Interface", "en0")])
        let outgoing = try node("Outgoing", "netout", [("Interface", "en0")])
        let total = try node("Total", "nettotal", [("Interface", "en0")])
        let bits = try node("Bits", "nettotal", [("Interface", "en0"), ("UseBits", "1")])
        let all = try node("All", "netin", [("Interface", "0")])
        let indexed = try node("Indexed", "netin", [("Interface", "2")])
        let cumulative = try node("Cumulative", "netin", [("Interface", "en0"), ("Cumulative", "1")])
        let fallback = try node("Fallback", "netin", [("Interface", "missing"), ("MaxValue", "8000")])
        let speed = try node("Speed", "netout", [("Interface", "en0"), ("NetOutSpeed", "500")])
        let nodes = [incoming, outgoing, total, bits, all, indexed, cumulative, fallback, speed]
        t.equal(system.requestedInterfaces, [], "constructors and options do not read network counters")
        t.equal(clockReads, 0)
        for measure in nodes { measure.performUpdate() }
        t.equal(nodes.map(\.value), [0, 0, 0, 0, 0, 0, 1000, 0, 0])
        t.equal(clockReads, 8, "cumulative data does not ask for a time")
        t.equal(system.requestedInterfaces, ["en0", "en0", "en0", "en0", nil, "en1", "en0", "en0", "en0"])
        system.counters = ["en0": NetworkCounters(received: 1400, sent: 700),
                           "en1": NetworkCounters(received: 300, sent: 150)]
        now = 102
        for measure in nodes { measure.performUpdate() }
        t.equal(nodes.map(\.value), [200, 100, 300, 2400, 300, 100, 1400, 200, 100])
        t.equal(clockReads, 16)
        t.equal(incoming.maxValue, 200)
        t.equal(fallback.maxValue, 1000, "MaxValue remains in bits for a byte-valued measure")
        t.equal(speed.maxValue, 500, "NetOutSpeed remains in bytes")
        fallback.needsOptionRead = true
        fallback.readOptionsIfNeeded()
        t.equal(context.logs, ["Notice: [Fallback] Interface=missing does not exist on this Mac; using the active interface"])
        system.counters["en0"] = NetworkCounters(received: 1600, sent: 900)
        incoming.performUpdate()
        t.equal(incoming.value, 0, "an equal-time sample gives zero and still replaces the previous sample")
        now = 103
        system.counters["en0"] = NetworkCounters(received: 1700, sent: 1000)
        incoming.performUpdate()
        t.equal(incoming.value, 100)
        now = 104
        system.counters["en0"] = NetworkCounters(received: 5, sent: 1000)
        incoming.performUpdate()
        t.equal(incoming.value, 0, "counter reversal gives zero")
        incoming.overrides["interface"] = "en1"
        incoming.needsOptionRead = true
        incoming.readOptionsIfNeeded()
        now = 105
        incoming.performUpdate()
        t.equal(incoming.value, 0, "an interface change forgets only this node's previous sample")

        let reads = system.requestedInterfaces.count
        incoming.setPaused(true)
        incoming.performUpdate()
        incoming.setPaused(false)
        incoming.setDisabled(true)
        incoming.performUpdate()
        t.equal(system.requestedInterfaces.count, reads)
        t.equal(incoming.value, 0)
        t.equal(context.services, Array(repeating: .system, count: nodes.count))

        let fast = try node("Fast", "netin", [("Interface", "en0")])
        let slow = try node("Slow", "netin", [("Interface", "en0")])
        now = 200
        system.counters["en0"] = NetworkCounters(received: 1000, sent: 0)
        fast.performUpdate(); slow.performUpdate()
        now = 201
        system.counters["en0"] = NetworkCounters(received: 1300, sent: 0)
        fast.performUpdate()
        t.equal(fast.value, 300)
        let pin = MeasureValueOverride()
        pin.pinned["fast"] = (value: 77, text: nil)
        context.measureValues = pin
        let beforePin = system.requestedInterfaces.count
        fast.performUpdate()
        t.equal(fast.value, 77)
        t.equal(system.requestedInterfaces.count, beforePin)
        pin.pinned.removeAll()
        now = 202
        system.counters["en0"] = NetworkCounters(received: 1400, sent: 0)
        fast.performUpdate(); slow.performUpdate()
        t.equal(fast.value, 100, "the pinned update leaves this node's rate history untouched")
        t.equal(slow.value, 200, "a slower node computes its own two-second delta")
    }

    t.suite("Engine: context builtin factory: exact classes preserve real registry and legacy construction") {
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-factory-negative"))
        for type in ["cpu", "string", "memory", "netin"] {
            t.check(makeContextBuiltinMeasure(ContextFactoryChild.self, name: "Custom",
                section: constructionSection("Custom", []), context: context, type: type) == nil,
                    "a built-in name never replaces a selected custom subclass")
        }
        t.check(makeContextBuiltinMeasure(TimeMeasure.self, name: "Time", section: constructionSection("Time", []),
                                         context: context, type: "time") == nil, "unqualified kernels retain legacy construction")
        // Unique names only: there is no unregister API, so canonical global registrations stay untouched.
        MeasureRegistry.registerMeasure("ContextFactoryOverrideProbe", ContextFactoryChild.self)
        MeasureRegistry.registerMeasure("ContextFactoryMemoryAlias", MemoryMeasure.self)
        let system = SectionConstructionSystem()
        system.cpu = 20
        system.memory = MemoryStatus(physicalTotal: 100, physicalUsed: 40, swapTotal: 20, swapUsed: 5)
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Update=-1
        [CPU]
        Measure=CPU
        Processor=2
        [Text]
        Measure=String
        String=factory
        [Physical]
        Measure=PhysicalMemory
        [Swap]
        Measure=SwapMemory
        [Memory]
        Measure=Memory
        [Incoming]
        Measure=NetIn
        Cumulative=1
        [Outgoing]
        Measure=NetOut
        Cumulative=1
        [Total]
        Measure=NetTotal
        Cumulative=1
        [Custom]
        Measure=ContextFactoryOverrideProbe
        [Alias]
        Measure=ContextFactoryMemoryAlias
        """, system: system)
        defer { skin.close() }
        skin.update()
        t.equal(skin.measures.map(\.value), [20, 0, 40, 45, 85, 1000, 500, 1500, 456, 85])
        for measure in skin.measures { t.check(measure.skin === skin) }
        t.check(skin.measure(named: "CPU") is CPUMeasure)
        t.check(skin.measure(named: "Text") is StringMeasure)
        t.equal(skin.measure(named: "Text")?.stringValue, "factory")
        guard let custom = skin.measure(named: "Custom") as? ContextFactoryChild else { throw SectionConstructionError.unexpectedKernel }
        t.equal(custom.constructorTrace, ["base:contextfactoryoverrideprobe", "child:contextfactoryoverrideprobe"])
        t.equal(custom.type, "contextfactoryoverrideprobe")
        t.check(skin.measure(named: "Alias") is MemoryMeasure)
        t.equal(skin.measure(named: "Alias")?.type, "contextfactorymemoryalias", "effectiveType is never canonicalized by the context helper")

        let directMemory = MemoryMeasure(name: "DirectMemory", section: constructionSection("DirectMemory", []),
                                         skin: skin, type: "swapmemory")
        directMemory.readOptionsIfNeeded(); directMemory.performUpdate()
        t.check(directMemory.skin === skin)
        t.equal(directMemory.value, 45)
        let directNet = NetMeasure(name: "DirectNet", section: constructionSection("DirectNet", [("Cumulative", "1")]),
                                   skin: skin, type: "netout")
        directNet.readOptionsIfNeeded(); directNet.performUpdate()
        t.check(directNet.skin === skin)
        t.equal(directNet.value, 500)
    }
}
