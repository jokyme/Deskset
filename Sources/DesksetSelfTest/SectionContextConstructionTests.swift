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
private class IndependentSectionContext: SectionContext {
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
    var locale: Locale
    var environment: SkinEnvironment?
    let directory: URL
    var skinsDirectory: URL { preconditionFailure("Unqualified skins directory in the construction fixture") }
    var orderedMeasures: [Measure] { preconditionFailure("Unqualified measure order in the construction fixture") }
    let sideEffects: SideEffects
    var styles: [String: IniSection] = [:]
    var variables: [String: String] = [:]
    var measures: [String: Measure] = [:]
    private(set) var services: [BackgroundWorkKind] = []
    private(set) var actions: [Bang] = []
    private(set) var logs: [String] = []
    private var logged: Set<String> = []
    private(set) var issues: Set<String> = []
    private var snapshotChanges = 0

    init(directory: URL, system: SystemDataSource = SectionConstructionSystem(),
         clock: @escaping () -> TimeInterval = { 86_400 }, skinClock: SkinClock? = nil,
         locale: Locale = Locale(identifier: "en_US_POSIX"), executor: SkinExecutor? = nil) throws {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw SectionConstructionError.utcUnavailable }
        let date = Date(timeIntervalSince1970: 1_798_761_598)
        self.directory = directory
        self.system = system
        self.clock = clock
        self.skinClock = skinClock ?? .fixed(date, timeZone: utc)
        self.locale = locale
        self.executor = executor ?? VirtualTimeExecutor(start: date, timeZone: utc)
        sideEffects = RecordingSideEffects(directory: directory.appendingPathComponent("effects"))
    }

    func measure(named name: String) -> Measure? {
        preconditionFailure("Unqualified measure lookup in the construction fixture")
    }
    func absolutePath(_ raw: String, relativeTo base: URL?) -> String {
        preconditionFailure("Unqualified absolute path in the construction fixture")
    }
    func allowsWebParserFileAccess(_ path: String) -> Bool {
        preconditionFailure("Unqualified WebParser file policy in the construction fixture")
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
    func currentEnvironment() -> SkinEnvironment { environment ?? SkinEnvironment(locale: locale) }
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

/// One coherent virtual clock and recorded processes. Only output delivery can be held; the real kernel still
/// decodes and writes the recording's file before publishing its result. No process or background queue starts.
private final class IndependentScheduledContext: IndependentSectionContext {
    let virtual: VirtualTimeExecutor
    var jobs: [BackgroundWorkKind] = []
    var holdOutput = false
    var heldOutput: [() -> Void] = []
    var actionTimes: [TimeInterval] = []
    var onAction: ((SkinSection?) -> Void)?

    init(directory: URL) throws {
        guard let utc = TimeZone(secondsFromGMT: 0) else { throw SectionConstructionError.utcUnavailable }
        let virtual = VirtualTimeExecutor(start: Date(timeIntervalSince1970: 1_798_761_598), timeZone: utc)
        self.virtual = virtual
        try super.init(directory: directory, clock: { virtual.uptime }, skinClock: virtual.clock, executor: virtual)
    }

    override func execute(_ actionText: String, from section: SkinSection?) {
        actionTimes.append(virtual.now)
        super.execute(actionText, from: section)
        onAction?(section)
    }
    override func async(_ work: @escaping () -> Void) {
        executor.async { [self] in
            assertOwned(#function)
            work()
        }
    }
    override func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void,
                                     orElse dropped: ((T) -> Void)?) {
        assertOwned(#function)
        precondition(!sideEffects.isLive && (job.kind == .runCommandProcess || job.kind == .runCommandOutput))
        guard let produce = job.inline else { preconditionFailure("Only recorded process work is qualified") }
        jobs.append(job.kind)
        let result = produce()
        let deliver = { [weak self] in
            guard let self else { dropped?(result); return }
            self.assertOwned(#function)
            completion(result)
        }
        if holdOutput && job.kind == .runCommandOutput { heldOutput.append(deliver) }
        else { executor.async(deliver) }
    }
    func deliverOutput() {
        let pending = heldOutput
        heldOutput = []
        for delivery in pending { executor.async(delivery) }
    }
}

private func runContextScheduledPluginTests(_ t: TestRunner) {
    t.suite("Engine: context scheduled plugins: timer uses its owner's clock and cancels lists on close") {
        let context = try IndependentScheduledContext(directory: t.temporaryDirectory("context-timer-clock"))
        let timer = try extendedNode(ActionTimerMeasure.self, "Timer", "actiontimer", [
            ("ActionList1", "A | Wait 100 | Repeat B, 50, 2 | C"),
            ("A", "[!Log A]"), ("B", "[!Log B]"), ("C", "[!Log C]"),
        ], in: context)
        timer.execute(command: "Execute 1")
        t.equal(timer.value, 0)
        t.equal(timer.runningLists, [1])
        t.equal(context.actions.count, 0, "the first action is queued after Execute")
        context.virtual.runUntilIdle()
        t.equal(context.actions.map(\.args), [["A"]])
        context.virtual.advance(by: 0.1)
        t.equal(context.actions.map(\.args), [["A"], ["B"]])
        context.virtual.advance(by: 0.05)
        t.equal(context.actions.map(\.args), [["A"], ["B"], ["B"], ["C"]])
        t.equal(context.actionTimes, [0, 0.1, 0.15, 0.15])
        t.equal(timer.runningLists, [])
        timer.execute(command: "Execute 1")
        context.virtual.runUntilIdle()
        t.equal(context.actions.count, 5)
        timer.skinWillClose()
        t.equal(timer.runningLists, [])
        t.equal(context.virtual.pendingCount, 0)
        timer.execute(command: "Execute 1")
        context.virtual.advance(by: 10)
        t.equal(context.actions.count, 5)
        t.equal(context.jobs, [])
    }

    t.suite("Engine: context scheduled plugins: timer reentry and release leave no scheduled work") {
        let context = try IndependentScheduledContext(directory: t.temporaryDirectory("context-timer-release"))
        var timer: ActionTimerMeasure? = try extendedNode(ActionTimerMeasure.self, "Timer", "actiontimer", [
            ("ActionList1", "A | Wait 100 | B"), ("A", "[!Log A]"), ("B", "[!Log B]"),
        ], in: context)
        context.onAction = { [weak timer] _ in timer?.execute(command: "Stop 1") }
        timer?.execute(command: "Execute 1")
        context.virtual.runUntilIdle()
        t.equal(timer?.runningLists, [])
        t.equal(context.actions.map(\.args), [["A"]])
        t.equal(context.virtual.pendingCount, 0)
        context.onAction = nil
        timer?.execute(command: "Execute 1")
        context.virtual.runUntilIdle()
        t.equal(context.virtual.pendingCount, 1)
        weak var released = timer
        context.measures.removeAll()
        timer = nil
        t.check(released == nil)
        t.equal(context.virtual.pendingCount, 0)
        context.virtual.advance(by: 10)
        t.equal(context.actions.map(\.args), [["A"], ["A"]])
    }

    t.suite("Engine: context scheduled plugins: command publishes saved output before FinishAction") {
        let context = try IndependentScheduledContext(directory: t.temporaryDirectory("context-command-output"))
        guard let effects = context.sideEffects as? RecordingSideEffects else { throw SectionConstructionError.unexpectedKernel }
        effects.programOutput = { _ in Data("hello 🐈\n".utf8) }
        context.holdOutput = true
        let command = try extendedNode(RunCommandMeasure.self, "Command", "runcommand", [
            ("Parameter", "printf fixture"), ("OutputFile", "output.txt"), ("OutputType", "UTF8"),
            ("Timeout", "5000"), ("FinishAction", "[!Log complete]"),
        ], in: context)
        let original = context.directory.appendingPathComponent("output.txt")
        let saved = effects.destination(forWriting: original)
        t.equal(command.value, -1)
        t.equal(command.rawString, "")
        var actionValues: [Double] = []
        var actionText: [String] = []
        var actionFiles: [Data?] = []
        context.onAction = { section in
            guard let measure = section as? RunCommandMeasure else { return }
            actionValues.append(measure.value)
            actionText.append(measure.stringValue)
            actionFiles.append(try? Data(contentsOf: saved))
        }
        command.execute(command: "Run")
        t.equal(command.value, 0)
        t.check(command.isRunning)
        t.equal(context.jobs, [.runCommandProcess])
        t.equal(context.actions.count, 0)
        context.virtual.runUntilIdle()
        t.equal(context.jobs, [.runCommandProcess, .runCommandOutput])
        t.equal(context.heldOutput.count, 1)
        t.equal(command.value, 0)
        t.equal(try Data(contentsOf: saved), Data("hello 🐈\n".utf8))
        t.check(!FileManager.default.fileExists(atPath: original.path), "only the recording's copy was written")
        command.execute(command: "Run")
        t.equal(command.value, 101)
        t.equal(context.jobs.count, 2, "a duplicate Run cannot start a second process during output delivery")
        context.deliverOutput()
        context.virtual.runUntilIdle()
        t.equal(command.value, 1)
        t.equal(command.stringValue, "hello 🐈\n")
        t.check(!command.isRunning)
        t.equal(actionValues, [1])
        t.equal(actionText, ["hello 🐈\n"])
        t.equal(actionFiles, [Data("hello 🐈\n".utf8)])
        command.skinWillClose()
        t.equal(context.virtual.pendingCount, 0)
    }

    t.suite("Engine: context scheduled plugins: close suppresses queued process and decoded output results") {
        for afterDecode in [false, true] {
            let context = try IndependentScheduledContext(directory: t.temporaryDirectory("context-command-close"))
            context.holdOutput = true
            let command = try extendedNode(RunCommandMeasure.self, "Command", "runcommand", [
                ("Parameter", "printf fixture"), ("Timeout", "5000"), ("FinishAction", "[!Log stale]"),
            ], in: context)
            command.execute(command: "Run")
            if afterDecode { context.virtual.runUntilIdle() }
            t.equal(context.heldOutput.count, afterDecode ? 1 : 0)
            command.skinWillClose()
            context.deliverOutput()
            context.virtual.advance(by: 10)
            t.equal(command.runningJobCount, 0)
            t.equal(command.value, 0, "late results do not publish into a closed owner")
            t.equal(context.actions.count, 0)
            t.equal(context.virtual.pendingCount, 0)
            command.execute(command: "Run")
            t.equal(context.jobs.count, afterDecode ? 2 : 1)
        }
    }

    t.suite("Engine: context scheduled plugins: background result does not retain a released owner") {
        var context: IndependentScheduledContext? = try IndependentScheduledContext(directory: t.temporaryDirectory("context-command-release"))
        guard let executor = context?.virtual else { throw SectionConstructionError.unexpectedKernel }
        weak var releasedOwner = context
        weak var releasedMeasure: RunCommandMeasure?
        if let context {
            let command = try extendedNode(RunCommandMeasure.self, "Command", "runcommand", [
                ("Parameter", "printf fixture"), ("Timeout", "5000"), ("FinishAction", "[!Log stale]"),
            ], in: context)
            releasedMeasure = command
            command.execute(command: "Run")
            t.equal(context.jobs, [.runCommandProcess])
        }
        context = nil
        t.check(releasedOwner == nil)
        t.check(releasedMeasure == nil)
        executor.advance(by: 10)
        t.equal(executor.pendingCount, 0)
    }

    t.suite("Engine: context scheduled plugins: failed starts use owner time and close cancels the action") {
        let context = try IndependentScheduledContext(directory: t.temporaryDirectory("context-command-failure"))
        let command = try extendedNode(RunCommandMeasure.self, "Command", "runcommand", [
            ("Program", "PowerShell"), ("FinishAction", "[!Log failed]"),
        ], in: context)
        command.execute(command: "Run")
        t.equal(command.value, 103)
        t.equal(context.actions.count, 0)
        context.virtual.runUntilIdle()
        t.equal(context.actions.count, 1)
        context.virtual.advance(by: 0.5)
        command.execute(command: "Run")
        context.virtual.runUntilIdle()
        t.equal(context.actions.count, 1, "a repeated failure within one owner-clock second is throttled")
        context.virtual.advance(by: 1)
        command.execute(command: "Run")
        context.virtual.runUntilIdle()
        t.equal(context.actions.count, 2)
        context.virtual.advance(by: 1)
        command.execute(command: "Run")
        command.skinWillClose()
        context.virtual.runUntilIdle()
        t.equal(context.actions.count, 2)
        t.equal(context.jobs, [], "an unsupported program never starts background work")
    }

    t.suite("Engine: context scheduled plugins: real registry aliases and legacy initializers stay compatible") {
        MeasureRegistry.registerMeasure("ContextScheduledTimerAlias", ActionTimerMeasure.self)
        MeasureRegistry.registerMeasure("ContextScheduledCommandAlias", RunCommandMeasure.self)
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Update=-1
        [Timer]
        Measure=Plugin
        Plugin=ActionTimer
        [Command]
        Measure=Plugin
        Plugin=RunCommand
        [TimerAlias]
        Measure=ContextScheduledTimerAlias
        [CommandAlias]
        Measure=ContextScheduledCommandAlias
        """)
        defer { skin.close() }
        t.check(skin.measure(named: "Timer") is ActionTimerMeasure)
        t.check(skin.measure(named: "Command") is RunCommandMeasure)
        t.check(skin.measure(named: "TimerAlias") is ActionTimerMeasure)
        t.check(skin.measure(named: "CommandAlias") is RunCommandMeasure)
        t.equal(skin.measure(named: "TimerAlias")?.type, "contextscheduledtimeralias")
        t.equal(skin.measure(named: "CommandAlias")?.type, "contextscheduledcommandalias")
        for measure in skin.measures { t.check(measure.skin === skin) }
        let timer = ActionTimerMeasure(name: "DirectTimer", section: constructionSection("DirectTimer", []), skin: skin, type: "actiontimer")
        let command = RunCommandMeasure(name: "DirectCommand", section: constructionSection("DirectCommand", []), skin: skin, type: "runcommand")
        t.check(timer.skin === skin && command.skin === skin)
        t.equal(timer.runningLists, [])
        t.equal(timer.value, 0)
        t.equal(command.value, -1)
        t.equal(command.rawString, "")
        t.equal(command.runningJobCount, 0)
    }
}

/// A file-only test owner. Real WebParser parsing and file writes run unchanged; results are deliberately
/// queued after production so tests can close or release the owner before delivery. No network start is allowed.
private final class IndependentWebParserContext: IndependentSectionContext {
    var ordered: [Measure] = []
    var allowedFiles: Set<String> = []
    var policyReads: [String] = []
    var jobs: [BackgroundWorkKind] = []
    var actionViews: [[String]] = []

    override var skinsDirectory: URL { directory }
    override var orderedMeasures: [Measure] { ordered }
    var virtual: VirtualTimeExecutor {
        guard let virtual = executor as? VirtualTimeExecutor else { preconditionFailure("Expected virtual executor") }
        return virtual
    }
    override func measure(named name: String) -> Measure? {
        measures[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }
    override func allowsWebParserFileAccess(_ path: String) -> Bool {
        policyReads.append(path)
        return allowedFiles.contains(path)
    }
    override func execute(_ actionText: String, from section: SkinSection?) {
        actionViews.append(ordered.map(\.stringValue))
        super.execute(actionText, from: section)
    }
    override func async(_ work: @escaping () -> Void) {
        executor.async { [self] in
            assertOwned(#function)
            work()
        }
    }
    override func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void,
                                     orElse dropped: ((T) -> Void)?) {
        assertOwned(#function)
        precondition(job.kind == .webParserPage || job.kind == .webParserDownload)
        if let path = job.reads {
            precondition(allowedFiles.contains((path as NSString).standardizingPath), "Only explicit fixture files")
        }
        guard let produce = job.inline else { preconditionFailure("No network in independent construction tests") }
        jobs.append(job.kind)
        let result = produce()
        executor.async { [weak self] in
            guard let self else { dropped?(result); return }
            self.assertOwned(#function)
            completion(result)
        }
    }
    func add(_ name: String, _ options: [(String, String)]) throws -> WebParserMeasure {
        guard let measure = makeContextBuiltinMeasure(WebParserMeasure.self, name: name,
            section: constructionSection(name, options), context: self, type: "webparser") as? WebParserMeasure else {
            throw SectionConstructionError.unexpectedKernel
        }
        measures[name.lowercased()] = measure
        ordered.append(measure)
        return measure
    }
    func prepare() {
        for measure in ordered { measure.readOptionsIfNeeded() }
        optionsLoaded = true
    }
}

private func runContextWebParserTests(_ t: TestRunner) {
    t.suite("Engine: context WebParser: ordered parent results precede actions without a Skin") {
        let context = try IndependentWebParserContext(directory: t.temporaryDirectory("context-web-tree"))
        let file = context.directory.appendingPathComponent("page.txt")
        try "42:hello".write(to: file, atomically: true, encoding: .utf8)
        context.allowedFiles = [file.path]
        let parent = try context.add("Parent", [
            ("URL", file.absoluteString), ("RegExp", #"(\d+):(\w+)"#), ("FinishAction", "[!Log parent]"),
        ])
        let second = try context.add("Second", [
            ("URL", "[pArEnT]"), ("StringIndex", "2"), ("RegExp", "(.*)"), ("FinishAction", "[!Log second]"),
        ])
        let first = try context.add("First", [
            ("URL", "[Parent]"), ("StringIndex", "1"), ("RegExp", "(.*)"), ("FinishAction", "[!Log first]"),
        ])
        t.equal([parent.rawString, second.rawString, first.rawString], ["", "", ""])
        context.prepare()
        parent.performUpdate()
        t.check(parent.isFetching)
        t.equal(context.ordered.map(\.stringValue), ["", "", ""])
        t.equal(context.actions.count, 0)
        context.virtual.runUntilIdle()
        t.check(!parent.isFetching)
        t.equal(context.ordered.map(\.stringValue), ["42:hello", "hello", "42"])
        t.equal(context.logs, ["Notice: parent", "Notice: second", "Notice: first"])
        t.equal(context.actionViews, Array(repeating: ["42:hello", "hello", "42"], count: 3),
                "all children have their result before even the parent's action")
        t.equal(parent.captures, ["42:hello", "42", "hello"])
        t.equal(context.jobs, [.webParserPage])
        parent.execute(command: "Reset")
        t.equal(context.ordered.map(\.stringValue), ["", "", ""])
        t.equal(context.ordered.map(\.value), [0, 0, 0])
        t.equal(context.actions.count, 3, "reset does not invent finish actions")
    }

    t.suite("Engine: context WebParser: superseded and closed results preserve the accepted state") {
        let context = try IndependentWebParserContext(directory: t.temporaryDirectory("context-web-generation"))
        let file = context.directory.appendingPathComponent("page.txt")
        try "11".write(to: file, atomically: true, encoding: .utf8)
        context.allowedFiles = [file.path]
        let parent = try context.add("Parent", [
            ("URL", file.absoluteString), ("RegExp", "(.*)"), ("FinishAction", "[!Log accepted]"),
        ])
        let child = try context.add("Child", [("URL", "[Parent]"), ("StringIndex", "1"), ("Disabled", "1")])
        context.prepare()
        parent.performUpdate()
        try "22".write(to: file, atomically: true, encoding: .utf8)
        parent.execute(command: "Update")
        context.virtual.runUntilIdle()
        t.equal(parent.stringValue, "22")
        t.equal(child.stringValue, "", "disabled children keep their displayed value")
        child.setDisabled(false)
        child.readOptionsIfNeeded()
        child.performUpdate()
        t.equal(child.stringValue, "22", "the disabled child's parsed result was still stored")
        t.equal(context.logs, ["Notice: accepted"])
        t.equal(parent.fetchCount, 2)
        try "33".write(to: file, atomically: true, encoding: .utf8)
        parent.execute(command: "Update")
        parent.skinWillClose()
        context.virtual.runUntilIdle()
        t.equal(parent.stringValue, "22")
        t.equal(child.stringValue, "22")
        t.equal(context.logs, ["Notice: accepted"], "late results run no actions")
        parent.execute(command: "Update")
        t.equal(parent.fetchCount, 3, "a closed node never starts another fetch")
    }

    t.suite("Engine: context WebParser: the independent owner decides file access") {
        let context = try IndependentWebParserContext(directory: t.temporaryDirectory("context-web-policy"))
        let file = context.directory.appendingPathComponent("page.txt")
        try "19".write(to: file, atomically: true, encoding: .utf8)
        let original = WebParserMeasure.allowsFileAccess
        var legacyPolicyCalls = 0
        WebParserMeasure.allowsFileAccess = { _, _ in legacyPolicyCalls += 1; return false }
        defer { WebParserMeasure.allowsFileAccess = original }
        let parent = try context.add("Parent", [
            ("URL", file.absoluteString), ("RegExp", "(.*)"), ("OnConnectErrorAction", "[!Log refused]"),
        ])
        context.prepare()
        parent.performUpdate()
        context.virtual.runUntilIdle()
        t.equal(parent.stringValue, "")
        t.equal(context.logs.last, "Notice: refused")
        t.equal(context.policyReads, [file.path])
        context.allowedFiles.insert(file.path)
        parent.execute(command: "Update")
        context.virtual.runUntilIdle()
        t.equal(parent.stringValue, "19")
        t.equal(context.policyReads, [file.path, file.path])
        t.equal(legacyPolicyCalls, 0, "independent construction never consults a Skin-only policy")
        t.equal(context.jobs, [.webParserPage, .webParserPage])
    }

    t.suite("Engine: context WebParser: downloads release files after delivery or owner loss") {
        func files(_ folder: URL) -> [URL] {
            let urls = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?
                .allObjects.compactMap { $0 as? URL } ?? []
            return urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        }
        for deliver in [true, false] {
            let directory = t.temporaryDirectory(deliver ? "context-web-download-deliver" : "context-web-download-drop")
            var context: IndependentWebParserContext? = try IndependentWebParserContext(directory: directory)
            guard let virtual = context?.virtual else { throw SectionConstructionError.unexpectedKernel }
            let file = directory.appendingPathComponent("source.bin")
            let bytes = Data([1, 4, 9, 16])
            try bytes.write(to: file)
            context?.allowedFiles = [file.path]
            var download = try context?.add("Download", [("URL", file.absoluteString), ("Download", "1")])
            weak var borrowedContext = context
            weak var borrowedDownload = download
            context?.prepare()
            download?.performUpdate()
            let written = files(directory.appendingPathComponent("effects"))
            t.equal(written.count, 1, "the real download save runs before the deferred completion")
            if let path = written.first { t.equal(try Data(contentsOf: path), bytes) }
            if deliver {
                virtual.runUntilIdle()
                t.equal(download.map { URL(fileURLWithPath: $0.stringValue).resolvingSymlinksInPath() },
                        written.first?.resolvingSymlinksInPath(),
                        "the delivered path names the exact saved file through the system temporary-directory alias")
                t.check(download?.isDownloading == false)
            }
            download = nil
            context = nil
            t.check(borrowedContext == nil)
            t.check(borrowedDownload == nil, "pending completions never retain the node or its owner")
            virtual.runUntilIdle()
            t.equal(files(directory.appendingPathComponent("effects")), [],
                    "deinit or the dropped-result callback removes the private temporary download")
            t.equal(try Data(contentsOf: file), bytes, "cleanup leaves the fixture source intact")
        }
    }

    t.suite("Engine: context WebParser: real factory aliases retain the required constructor state") {
        MeasureRegistry.registerMeasure("ContextFactoryWebParserAlias", WebParserMeasure.self)
        let (skin, _) = try makeSkin(t, """
        [Rainmeter]
        Update=-1
        [Page]
        Measure=ContextFactoryWebParserAlias
        Disabled=1
        URL=https://example.invalid/never-started
        """)
        defer { skin.close() }
        guard let selected = skin.measure(named: "Page") as? WebParserMeasure else {
            throw SectionConstructionError.unexpectedKernel
        }
        let legacy = WebParserMeasure(name: "Legacy", section: constructionSection("Legacy", [("Disabled", "1")]),
                                      skin: skin, type: "webparser")
        t.check(selected.skin === skin)
        t.equal(selected.type, "contextfactorywebparseralias")
        t.equal(selected.rawString, "")
        t.equal(selected.rawString, legacy.rawString)
        t.equal(selected.fetchCount, 0)
        t.check(!selected.isFetching && !selected.isDownloading)
        skin.update()
        t.equal(selected.fetchCount, 0)
        t.equal(selected.stringValue, "")
    }
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
    runContextBuiltinExtendedTests(t)
    runContextRegistryTests(t)
    runContextWebParserTests(t)
    runContextScheduledPluginTests(t)
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
        t.check(makeContextBuiltinMeasure(ScriptMeasure.self, name: "Script", section: constructionSection("Script", []),
                                         context: context, type: "script") == nil, "unqualified kernels retain legacy construction")
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

/// Direct protocol witnesses avoid the real-volume defaults and the global hardware-sensor fallback.
/// The existing deterministic engine source supplies values; this wrapper observes their actual read order.
private final class ContextBuiltinSystem: SystemDataSource, HardwareSensorSource {
    let values = EngineTestSystem()
    private(set) var calls: [String] = []
    var sensors: [String: Double] = [SensorKeys.frequencyCPU: 2100]
    var wallpaper: String?

    func resetCalls() { calls.removeAll() }
    var processorCount: Int { calls.append("processorCount"); return values.processorCount }
    func cpuUsage(processor: Int) -> Double { calls.append("cpu:\(processor)"); return values.cpuUsage(processor: processor) }
    func memoryStatus() -> MemoryStatus { calls.append("memory"); return values.memoryStatus() }
    func networkInterfaces() -> [String] { calls.append("interfaces"); return values.networkInterfaces() }
    func networkCounters(interface: String?) -> NetworkCounters {
        calls.append("network:\(interface ?? "all")"); return values.networkCounters(interface: interface)
    }
    func diskSpace(path: String) -> (total: Double, free: Double)? {
        calls.append("disk:\(path)"); return values.diskSpace(path: path)
    }
    func availableDiskSpace(path: String) -> Double? {
        calls.append("available:\(path)"); return values.availableDiskSpace(path: path)
    }
    func uptime() -> TimeInterval { calls.append("uptime"); return values.uptime() }
    func battery() -> BatteryStatus? { calls.append("battery"); return values.battery() }
    func isProcessRunning(_ name: String) -> Bool { calls.append("process:\(name)"); return values.isProcessRunning(name) }
    func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
        calls.append("sysInfo:\(type):\(data)"); return values.sysInfo(type: type, data: data)
    }
    func bestNetworkInterface() -> String? { calls.append("bestInterface"); return values.bestNetworkInterface() }
    func volumeInfo(path: String) -> VolumeInfo? { calls.append("volume:\(path)"); return values.volumeInfo(path: path) }
    func cpuFrequency() -> Double? { calls.append("frequency"); return values.cpuFrequency() }
    func desktopPicturePath() -> String? { calls.append("desktopPicture"); return wallpaper }
    func graphicsAdapterName() -> String? { calls.append("graphics"); return values.graphicsAdapterName() }
    func sensorValue(_ key: String) -> Double? { calls.append("sensor:\(key)"); return sensors[key] }
}

private func extendedNode<T: Measure>(_ cls: T.Type, _ name: String, _ type: String,
                                     _ options: [(String, String)], in context: IndependentSectionContext) throws -> T {
    guard let node = makeContextBuiltinMeasure(cls, name: name, section: constructionSection(name, options),
                                              context: context, type: type) as? T else {
        throw SectionConstructionError.unexpectedKernel
    }
    context.measures[name.lowercased()] = node
    return node
}

/// The normal Skin loader, with private synthetic input and the real protocol source. The caller keeps the weak
/// host alive until close; unlike the independent suites below this control deliberately owns a real Skin.
private func extendedConsumerSkin(_ t: TestRunner, _ ini: String, system: SystemDataSource,
                                  host: EnvironmentHost, clock: SkinClock) throws -> Skin {
    let skins = t.temporaryDirectory("context-extended-consumer").appendingPathComponent("Skins")
    let dir = skins.appendingPathComponent("Root/Sub")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: skins.appendingPathComponent("Root/@Resources"), withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("Skin.ini")
    try ini.write(to: file, atomically: true, encoding: .utf8)
    let skin = Skin(config: "Root\\Sub", fileURL: file, skinsDirectory: skins, system: system, host: host)
    skin.skinClock = clock
    skin.random = SkinRandom(seed: 1)
    try skin.load()
    return skin
}

private func runContextBuiltinExtendedTests(_ t: TestRunner) {
    t.suite("Engine: context builtin extended: Calc reads live state and preserves random and error history") {
        let system = ContextBuiltinSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-calc"), system: system)
        context.optionsLoaded = true
        context.counter = 2
        let state = StringMeasure(name: "State", section: constructionSection("State", [("String", "1")]), context: context, type: "string")
        context.measures["state"] = state
        state.readOptionsIfNeeded(); state.performUpdate()
        let calc = try extendedNode(CalcMeasure.self, "Calc", "calc", [("Formula", "State+Counter"),
                                    ("OnUpdateAction", "[!Canary 7]")], in: context)
        calc.readOptionsIfNeeded(); calc.performUpdate()
        t.equal(calc.value, 3)
        t.equal(state.value, 7)
        t.equal(context.actions, [Bang(name: "canary", args: ["7"])])
        context.counter = 3
        calc.performUpdate()
        t.equal(calc.value, 10, "the next call reads the adjacent measure changed by the preceding synchronous action")
        calc.overrides["formula"] = "Missing+1"
        calc.needsOptionRead = true
        calc.readOptionsIfNeeded(); calc.performUpdate(); calc.performUpdate()
        t.equal(calc.value, 10)
        t.equal(context.logs.filter { $0.contains("cannot evaluate Formula") }.count, 1)
        for bad in ["(", "?"] {
            calc.overrides["formula"] = bad
            calc.needsOptionRead = true
            calc.readOptionsIfNeeded(); calc.performUpdate()
        }
        t.equal(context.logs.filter { $0.contains("invalid Formula") }.count, 1)

        let randomOptions = [("Formula", "Random"), ("LowBound", "1"), ("HighBound", "3"),
                             ("UpdateRandom", "1"), ("UniqueRandom", "1")]
        let random = try extendedNode(CalcMeasure.self, "Random", "calc", randomOptions, in: context)
        random.readOptionsIfNeeded()
        var first: [Double] = []
        for _ in 0..<3 { random.performUpdate(); first.append(random.value) }
        t.equal(Set(first), Set([1.0, 2.0, 3.0]))
        let other = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-calc-seed"), system: system)
        let repeated = try extendedNode(CalcMeasure.self, "Random", "calc", randomOptions, in: other)
        repeated.readOptionsIfNeeded()
        var second: [Double] = []
        for _ in 0..<3 { repeated.performUpdate(); second.append(repeated.value) }
        t.equal(second, first, "the existing per-owner seed advances at the same kernel call sites")
        let once = try extendedNode(CalcMeasure.self, "Once", "calc", [("Formula", "Random"), ("LowBound", "10"), ("HighBound", "20")], in: context)
        once.readOptionsIfNeeded(); once.performUpdate()
        let held = once.value
        t.check((10...20).contains(held))
        once.performUpdate()
        t.equal(once.value, held)
        once.overrides["lowbound"] = "30"; once.overrides["highbound"] = "30"
        once.needsOptionRead = true
        once.readOptionsIfNeeded(); once.performUpdate()
        t.equal(once.value, 30)
        t.equal(context.services, [])
        t.equal(system.calls, [])
    }

    t.suite("Engine: context builtin extended: Loop cadence reset and borrowed ownership remain local") {
        let system = ContextBuiltinSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-loop"), system: system)
        let forward = try extendedNode(LoopMeasure.self, "Forward", "loop", [("StartValue", "0"), ("EndValue", "10"),
            ("Increment", "3"), ("AverageSize", "3"), ("MinValue", "-100"), ("MaxValue", "200")], in: context)
        let reverse = try extendedNode(LoopMeasure.self, "Reverse", "loop", [("StartValue", "10"), ("EndValue", "0"),
            ("Increment", "-5"), ("LoopCount", "1")], in: context)
        forward.readOptionsIfNeeded(); reverse.readOptionsIfNeeded()
        var a: [Double] = [], b: [Double] = []
        for index in 0..<7 {
            forward.performUpdate(); a.append(forward.value)
            if index % 2 == 0 { reverse.performUpdate(); b.append(reverse.value) }
        }
        t.equal(a, [0, 3, 6, 9, 10, 0, 3])
        t.equal(b, [10, 5, 0, 0])
        t.equal(forward.minValue, 0)
        t.equal(forward.maxValue, 10)
        t.equal(forward.averageSize, 1)
        t.equal(forward.runtimeSnapshot.average, nil)
        forward.execute(command: " Reset "); forward.performUpdate()
        t.equal(forward.value, 0)
        forward.overrides["endvalue"] = "20"; forward.needsOptionRead = true
        forward.readOptionsIfNeeded(); forward.performUpdate()
        t.equal(forward.value, 0)
        forward.overrides["invertmeasure"] = "1"; forward.needsOptionRead = true
        forward.readOptionsIfNeeded(); forward.performUpdate()
        t.equal(forward.value, 20)
        t.equal(reverse.value, 0, "resetting one kernel does not advance another")
        t.equal(context.services, [])
        t.equal(system.calls, [])

        var owner: IndependentSectionContext? = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-loop-lifetime"), system: system)
        weak var weakOwner = owner
        let retained = try extendedNode(LoopMeasure.self, "Retained", "loop", [], in: owner!)
        retained.readOptionsIfNeeded(); retained.performUpdate()
        t.equal(retained.value, 1)
        owner = nil
        t.check(weakOwner == nil)
        withExtendedLifetime(retained) {} // Never dereference the unowned context after release.
    }

    t.suite("Engine: context builtin extended: ordinary Time uses the injected clock zone and locale") {
        guard let shanghai = TimeZone(identifier: "Asia/Shanghai") else { throw SectionConstructionError.utcUnavailable }
        let date = Date(timeIntervalSince1970: 1_798_761_598)
        var nowReads = 0, zoneReads = 0
        let clock = SkinClock(now: { nowReads += 1; return date }, uptime: { 1 }, timeZone: { zoneReads += 1; return shanghai })
        let system = ContextBuiltinSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-time"), system: system, skinClock: clock)
        let local = try extendedNode(TimeMeasure.self, "Local", "time", [], in: context)
        t.equal([nowReads, zoneReads], [0, 0], "construction does not force lazy time zone or sampling")
        local.readOptionsIfNeeded()
        t.equal([nowReads, zoneReads], [1, 1])
        local.performUpdate()
        t.equal([nowReads, zoneReads], [2, 1])
        t.equal(local.value, 13_443_263_998)
        t.equal(local.timestamp, 13_443_263_998)
        t.equal(local.rawString, "07:59:58")
        let cases: [(String, [(String, String)], Double, String)] = [
            ("Formatted", [("Format", "%Y-%m-%d %H:%M:%S")], 2027, "2027-01-01 07:59:58"),
            ("Offset", [("Format", "%H:%M"), ("TimeZone", "-5"), ("DaylightSavingTime", "0")], 18, "18:59"),
            ("Locale", [("Format", "%A %#d %B"), ("FormatLocale", "Local")], 0, "Friday 1 January"),
            ("Numeric", [("TimeStamp", "13000000000")], 13_000_000_000, "23:06:40"),
            ("Parsed", [("TimeStamp", "2026-12-31 23:59:58"), ("TimeStampFormat", "%Y-%m-%d %H:%M:%S")], 13_443_235_198, "23:59:58"),
        ]
        for (name, options, value, text) in cases {
            let node = try extendedNode(TimeMeasure.self, name, "time", options, in: context)
            node.readOptionsIfNeeded(); node.performUpdate()
            t.equal(node.value, value)
            t.equal(node.rawString, text)
            if name == "Numeric" || name == "Parsed" { t.equal(node.timestamp, value) }
        }
        let invalid = try extendedNode(TimeMeasure.self, "Invalid", "time", [("TimeStamp", "not-a-timestamp")], in: context)
        invalid.readOptionsIfNeeded(); invalid.performUpdate(); invalid.performUpdate()
        t.equal(invalid.value, 0)
        t.equal(invalid.timestamp, 0)
        t.equal(context.logs.filter { $0.contains("does not match TimeStampFormat") }.count, 1)
        t.equal(context.services, [])
        t.equal(system.calls, [])
    }

    t.suite("Engine: context builtin extended: Time override keeps original live-read and stored timestamp semantics") {
        guard let newYork = TimeZone(identifier: "America/New_York"), let utc = TimeZone(secondsFromGMT: 0) else { throw SectionConstructionError.utcUnavailable }
        var date = Date(timeIntervalSince1970: 1_798_761_598), zone = newYork
        var nowReads = 0, zoneReads = 0
        let clock = SkinClock(now: { nowReads += 1; return date }, uptime: { 1 }, timeZone: { zoneReads += 1; return zone })
        let system = ContextBuiltinSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-time-override"), system: system, skinClock: clock)
        context.optionsLoaded = true
        context.variables["mask"] = "%H:%M"
        let time = try extendedNode(TimeMeasure.self, "Time", "time", [("Format", "#Mask#"), ("FormatLocale", "Local")], in: context)
        let plain = try extendedNode(TimeMeasure.self, "Plain", "time", [], in: context)
        let fixed = try extendedNode(TimeMeasure.self, "Fixed", "time", [("TimeStamp", "13000000000")], in: context)
        for node in [time, plain, fixed] { node.readOptionsIfNeeded(); node.performUpdate() }
        t.equal(time.value, 18)
        t.equal(time.rawString, "18:59")
        t.equal(time.timestamp, 13_443_217_198)
        let stored = time.timestamp
        let sample = MeasureValueOverride()
        sample.frozenTime = Date(timeIntervalSince1970: 1_798_761_600)
        sample.pinned["time"] = (77, "pinned")
        context.measureValues = sample
        let beforePin = [nowReads, zoneReads]
        time.performUpdate()
        t.equal(time.value, 77)
        t.equal(time.rawString, "pinned")
        t.equal(time.timestamp, stored)
        t.equal([nowReads, zoneReads], beforePin)
        sample.pinned.removeAll()
        zone = utc
        let beforeFrozen = [nowReads, zoneReads]
        time.performUpdate(); plain.performUpdate()
        t.equal(time.value, 0)
        t.equal(time.rawString, "00:00")
        t.equal(time.timestamp, stored, "frozen show never rewrites normal compute's stored timestamp")
        t.equal(plain.value, 13_443_235_200)
        t.equal(plain.timestamp, 13_443_217_198)
        t.equal(nowReads, beforeFrozen[0])
        t.equal(zoneReads, beforeFrozen[1] + 2)
        context.variables["mask"] = "%B"
        context.locale = Locale(identifier: "fr_FR")
        time.performUpdate()
        t.equal(time.rawString, "janvier", "frozen show re-reads the resolver and Local locale without another options read")
        t.equal(time.value, 0)
        t.equal(time.timestamp, stored)
        let beforeFixed = [nowReads, zoneReads]
        fixed.performUpdate()
        t.equal(fixed.value, 13_000_000_000, "an explicit TimeStamp refuses frozen show")
        t.equal([nowReads, zoneReads], [beforeFixed[0] + 1, beforeFixed[1] + 1])

        zone = newYork
        let dst = try extendedNode(TimeMeasure.self, "DST", "time", [("Format", "%H"), ("TimeZone", "-5"), ("DaylightSavingTime", "1")], in: context)
        dst.readOptionsIfNeeded()
        context.measureValues = nil
        dst.performUpdate()
        t.equal(dst.value, 18)
        let winterStamp = dst.timestamp
        context.measureValues = sample
        sample.frozenTime = Date(timeIntervalSince1970: 1_784_116_800)
        let beforeDST = nowReads
        dst.performUpdate()
        t.equal(dst.value, 8, "numeric zone DST uses the frozen summer instant, not the cached winter zone")
        t.equal(dst.timestamp, winterStamp)
        t.equal(nowReads, beforeDST)
        let beforePaused = time.updateCount
        time.setPaused(true); time.performUpdate()
        t.equal(time.updateCount, beforePaused)
        time.setPaused(false); time.setDisabled(true); time.performUpdate()
        t.equal(time.value, 0)
        t.equal(time.updateCount, beforePaused)
        time.setDisabled(false)
        context.measureValues = nil
        context.variables["mask"] = "%H"
        zone = utc
        date = Date(timeIntervalSince1970: 1_798_761_598)
        time.readOptionsIfNeeded(); time.performUpdate()
        t.equal(time.value, 23)
        t.equal(time.rawString, "23")
        t.equal(time.timestamp, 13_443_235_198)
        t.equal(context.services, [])
        t.equal(system.calls, [])
    }

    t.suite("Engine: context builtin extended: Uptime and Process keep service notes separate from reads") {
        let system = ContextBuiltinSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-uptime-process"), system: system)
        let fixed = try extendedNode(UptimeMeasure.self, "Fixed", "uptime", [("SecondsValue", "3725"), ("Format", "%3!i!h %2!02i!m %1!02i!s")], in: context)
        fixed.readOptionsIfNeeded(); fixed.performUpdate()
        t.equal(fixed.value, 3725)
        t.equal(fixed.rawString, "1h 02m 05s")
        t.equal(system.calls, [])
        t.equal(context.services, [])
        let uptime = try extendedNode(UptimeMeasure.self, "Uptime", "uptime", [("Format", "%3!i!:%2!02i!")], in: context)
        uptime.readOptionsIfNeeded(); uptime.performUpdate()
        t.equal(uptime.value, 90061)
        t.equal(uptime.rawString, "25:01")
        t.equal(system.calls, ["uptime"], "uptime still reads SystemDataSource, not the context's monotonic clock")
        let process = try extendedNode(ProcessMeasure.self, "Process", "process", [("ProcessName", " Finder.exe ")], in: context)
        let gone = try extendedNode(ProcessMeasure.self, "Gone", "process", [("ProcessName", "Nothing.exe")], in: context)
        let empty = try extendedNode(ProcessMeasure.self, "Empty", "process", [], in: context)
        for node in [process, gone, empty] { node.readOptionsIfNeeded(); node.performUpdate() }
        t.equal([process.value, gone.value, empty.value], [1, -1, -1])
        t.equal(process.minValue, -1)
        t.equal(system.calls, ["uptime", "process:Finder", "process:Nothing"])
        t.equal(context.services, Array(repeating: .system, count: 4), "the empty process still notes its existing live-input class")
        let before = system.calls
        process.setPaused(true); process.performUpdate()
        process.setPaused(false); process.setDisabled(true); process.performUpdate()
        t.equal(system.calls, before)
        t.equal(process.value, 0)
        process.setDisabled(false)
        let sample = MeasureValueOverride(); sample.data = .noData; context.measureValues = sample
        process.performUpdate()
        t.equal(process.value, 0)
        t.equal(system.calls, before)
    }

    t.suite("Engine: context builtin extended: FreeDisk witnesses preserve loading and volume branches") {
        let system = ContextBuiltinSystem()
        system.values.available = nil
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-disk"), system: system)
        let available = try extendedNode(FreeDiskSpaceMeasure.self, "Available", "freediskspace", [("Drive", "/fixture"), ("MacAvailable", "1"), ("AverageSize", "3")], in: context)
        let used = try extendedNode(FreeDiskSpaceMeasure.self, "Used", "freediskspace", [("Drive", "/fixture"), ("MacAvailable", "1"), ("InvertMeasure", "1")], in: context)
        t.equal(system.calls, [], "even FreeDisk construction does not read a volume")
        available.readOptionsIfNeeded(); used.readOptionsIfNeeded()
        t.equal(system.calls, ["disk:/fixture", "disk:/fixture"], "the original automatic max is read in option order")
        system.resetCalls()
        available.performUpdate(); used.performUpdate()
        t.equal([available.value, used.value], [-1, -1])
        t.equal(available.rawString, "")
        t.check(available.valueUnavailable && used.valueUnavailable)
        t.equal(available.runtimeSnapshot.average, nil)
        t.equal(system.calls, ["volume:/fixture", "disk:/fixture", "available:/fixture", "volume:/fixture", "disk:/fixture", "available:/fixture"])
        system.values.available = 600
        available.performUpdate(); used.performUpdate()
        t.equal([available.value, used.value], [600, 400])
        t.check(!available.valueUnavailable && !used.valueUnavailable)
        t.equal(available.runtimeSnapshot.average, SkinRuntimeState.Average(samples: [600], next: 1))
        system.values.available = 5000
        available.performUpdate()
        t.equal(available.value, 800, "available bytes clamp before entering the existing numeric average")
        t.equal(available.runtimeSnapshot.average, SkinRuntimeState.Average(samples: [600, 1000], next: 2))

        system.values.disk = nil; system.values.volume = nil
        let missing = try extendedNode(FreeDiskSpaceMeasure.self, "Missing", "freediskspace", [("Drive", "/fixture")], in: context)
        missing.readOptionsIfNeeded(); system.resetCalls(); missing.performUpdate()
        t.equal(missing.value, 0)
        t.check(!missing.valueUnavailable)
        t.equal(system.calls, ["volume:/fixture", "disk:/fixture"])
        system.values.disk = (1000, 250)
        system.values.volume = VolumeInfo(label: "USB", kind: .removable)
        let ignored = try extendedNode(FreeDiskSpaceMeasure.self, "Ignored", "freediskspace", [("Drive", "/fixture")], in: context)
        ignored.readOptionsIfNeeded(); system.resetCalls(); ignored.performUpdate()
        t.equal(ignored.value, 0)
        t.equal(system.calls, ["volume:/fixture"])
        let type = try extendedNode(FreeDiskSpaceMeasure.self, "Type", "freediskspace", [("Drive", "/fixture"), ("Type", "1")], in: context)
        type.readOptionsIfNeeded(); system.resetCalls(); type.performUpdate()
        t.equal(type.value, 3)
        t.equal(type.rawString, "Removable")
        t.equal(system.calls, ["volume:/fixture", "disk:/fixture"], "Type's value bypasses disk data, while the old numeric range still reads its automatic max")
        let label = try extendedNode(FreeDiskSpaceMeasure.self, "Label", "freediskspace", [("Drive", "/fixture"), ("Label", "1"), ("IgnoreRemovable", "0")], in: context)
        label.readOptionsIfNeeded(); system.resetCalls(); label.performUpdate()
        t.equal(label.value, 250)
        t.equal(label.rawString, "USB")
        t.equal(system.calls, ["volume:/fixture", "disk:/fixture"])
        let total = try extendedNode(FreeDiskSpaceMeasure.self, "Total", "freediskspace", [("Drive", "/fixture"), ("Total", "1"), ("MacAvailable", "1"), ("IgnoreRemovable", "0")], in: context)
        total.readOptionsIfNeeded(); system.resetCalls(); total.performUpdate()
        t.equal(total.value, 1000)
        t.equal(system.calls, ["volume:/fixture", "disk:/fixture"], "Total bypasses available-space reading")
    }

    t.suite("Engine: context builtin extended: SysInfo uses current environment and explicit source answers") {
        guard let newYork = TimeZone(identifier: "America/New_York") else { throw SectionConstructionError.utcUnavailable }
        var date = Date(timeIntervalSince1970: 1_798_761_598)
        let clock = SkinClock(now: { date }, uptime: { 1 }, timeZone: { newYork })
        let system = ContextBuiltinSystem()
        system.values.sysInfoAnswers["SCREEN_WIDTH"] = (999, nil)
        system.values.sysInfoAnswers["NONFINITE"] = (.nan, nil)
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-sysinfo"), system: system, skinClock: clock)
        let environmentHost = EnvironmentHost()
        context.environment = environmentHost.env
        let cases: [(String, String, String, Double, String?)] = [
            ("Monitors", "NUM_MONITORS", "", 2, nil), ("Width", "SCREEN_WIDTH", "2", 1280, nil),
            ("Work", "WORK_AREA", "", 0, "1920 x 1055"), ("Bits", "OS_BITS", "", 64, nil),
            ("User", "USER_NAME", "", 0, "tester"), ("Finite", "NONFINITE", "", 0, nil),
        ]
        for (name, type, data, value, text) in cases {
            let node = try extendedNode(SysInfoMeasure.self, name, "sysinfo", [("SysInfoType", type), ("SysInfoData", data)], in: context)
            node.readOptionsIfNeeded(); node.performUpdate()
            t.equal(node.value, value)
            t.equal(node.rawString, text)
            t.check(!node.valueUnavailable)
        }
        t.equal(system.calls, ["sysInfo:USER_NAME:", "sysInfo:NONFINITE:"], "engine environment answers take precedence over the source")
        let sid = try extendedNode(SysInfoMeasure.self, "SID", "sysinfo", [("SysInfoType", "USER_SID")], in: context)
        sid.readOptionsIfNeeded(); sid.performUpdate(); sid.performUpdate()
        t.equal(sid.value, 0)
        t.equal(sid.rawString, "")
        t.check(sid.valueUnavailable)
        t.equal(context.issues, Set(["SysInfoType=USER_SID is not supported on macOS"]))
        let unknown = try extendedNode(SysInfoMeasure.self, "Unknown", "sysinfo", [("SysInfoType", "USER_NAMES")], in: context)
        unknown.readOptionsIfNeeded(); unknown.performUpdate(); unknown.performUpdate()
        t.equal(unknown.value, 0)
        t.equal(unknown.rawString, "")
        t.check(!unknown.valueUnavailable)
        t.equal(context.logs.filter { $0.contains("USER_NAMES is not a SysInfo type") }.count, 1)
        let dst = try extendedNode(SysInfoMeasure.self, "DST", "sysinfo", [("SysInfoType", "TIMEZONE_ISDST")], in: context)
        let bias = try extendedNode(SysInfoMeasure.self, "Bias", "sysinfo", [("SysInfoType", "TIMEZONE_BIAS")], in: context)
        dst.readOptionsIfNeeded(); bias.readOptionsIfNeeded(); dst.performUpdate(); bias.performUpdate()
        t.equal(dst.value, 0)
        t.equal(bias.value, 300)
        date = Date(timeIntervalSince1970: 1_784_116_800)
        let sample = MeasureValueOverride(); sample.frozenTime = Date(timeIntervalSince1970: 1_798_761_598)
        context.measureValues = sample
        dst.performUpdate()
        t.equal(dst.value, 1, "Time's frozen-date override does not replace SysInfo's own context clock read")
        context.environment?.screens = []
        let beforeEmpty = system.calls
        context.measures["monitors"]?.performUpdate(); context.measures["width"]?.performUpdate()
        t.equal(context.measures["monitors"]?.value, 0)
        t.equal(context.measures["width"]?.value, 0)
        t.equal(system.calls, beforeEmpty, "an empty supplied screen list is an engine answer, not a source fallback")
    }

    t.suite("Engine: context builtin extended: Power keeps battery rated and sensor witness order") {
        let system = ContextBuiltinSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-power"), system: system)
        let states = ["ACLine", "Status", "Status2", "Lifetime", "Percent", "Hz", "MHz"]
        let nodes = try states.map { try extendedNode(PowerPluginMeasure.self, $0, "powerplugin", [("PowerState", $0)], in: context) }
        for node in nodes { node.readOptionsIfNeeded() }
        t.equal(system.calls, [])
        t.equal(context.services, [])
        for node in nodes { node.performUpdate() }
        t.equal(nodes.map(\.value), [0, 4, 1, 5400, 80, 3_200_000_000, 3200])
        t.equal(nodes[3].rawString, "01:30")
        t.equal(system.calls, ["battery", "battery", "battery", "battery", "battery", "battery", "frequency", "battery", "frequency"])
        t.equal(context.services, Array(repeating: [.battery, .system], count: 7).flatMap { $0 })
        system.values.batteryStatus = BatteryStatus(percent: 3, isCharging: true, isPluggedIn: true)
        for node in nodes.prefix(5) { node.performUpdate() }
        t.equal(Array(nodes.prefix(5)).map(\.value), [1, 1, 14, -1, 3])
        t.equal(nodes[3].rawString, "Unknown")
        system.values.batteryStatus = nil
        for node in nodes.prefix(5) { node.performUpdate() }
        t.equal(Array(nodes.prefix(5)).map(\.value), [1, 0, 128, -1, 100])
        system.values.frequency = nil
        system.resetCalls()
        nodes[5].performUpdate(); nodes[6].performUpdate()
        t.equal([nodes[5].value, nodes[6].value], [2_100_000_000, 2100])
        t.equal(system.calls, ["battery", "frequency", "sensor:frequency.cpu", "battery", "frequency", "sensor:frequency.cpu"])
        system.sensors.removeAll()
        system.resetCalls(); nodes[5].performUpdate()
        t.equal(nodes[5].value, 0)
        t.equal(system.calls, ["battery", "frequency", "sensor:frequency.cpu"], "a nil reading remains on the injected source, never the global source")
        nodes[3].overrides["powerstate"] = "Percent"; nodes[3].needsOptionRead = true
        nodes[3].readOptionsIfNeeded(); nodes[3].performUpdate()
        t.equal(nodes[3].value, 100)
        t.equal(nodes[3].rawString, nil, "changing away from Lifetime drops the former text")
    }

    t.suite("Engine: context builtin extended: real Skin consumer and old required constructors agree") {
        let system = ContextBuiltinSystem()
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-extended-constructor"), system: system)
        let classes: [(Measure.Type, String)] = [(CalcMeasure.self, "calc"), (LoopMeasure.self, "loop"),
            (TimeMeasure.self, "time"), (UptimeMeasure.self, "uptime"), (FreeDiskSpaceMeasure.self, "freediskspace"),
            (ProcessMeasure.self, "process"), (SysInfoMeasure.self, "sysinfo"), (PowerPluginMeasure.self, "powerplugin")]
        for (cls, type) in classes {
            let node = makeContextBuiltinMeasure(cls, name: type, section: constructionSection(type, []), context: context, type: type)
            t.check(node != nil)
            if let node { t.check(ObjectIdentifier(Swift.type(of: node)) == ObjectIdentifier(cls)) }
            t.check(makeContextBuiltinMeasure(ContextFactoryChild.self, name: type, section: constructionSection(type, []), context: context, type: type) == nil,
                    "exact dispatch never substitutes a selected registered subclass")
        }
        t.equal(system.calls, [])
        t.equal(context.services, [])
        guard let shanghai = TimeZone(identifier: "Asia/Shanghai") else { throw SectionConstructionError.utcUnavailable }
        let host = EnvironmentHost()
        host.env.locale = Locale(identifier: "en_US_POSIX")
        let skin = try extendedConsumerSkin(t, """
        [Rainmeter]
        Update=-1
        [Calc]
        Measure=Calc
        Formula=2+3
        [Loop]
        Measure=Loop
        StartValue=0
        EndValue=10
        Increment=3
        [Time]
        Measure=Time
        [Uptime]
        Measure=Uptime
        SecondsValue=3725
        [Disk]
        Measure=FreeDiskSpace
        Drive=/fixture
        Label=1
        [Process]
        Measure=Process
        ProcessName=Finder.exe
        [SysInfo]
        Measure=SysInfo
        SysInfoType=SCREEN_WIDTH
        SysInfoData=2
        [Power]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=MHz
        [ProcessAlias]
        Measure=Plugin
        Plugin=Plugins\\Process.dll
        ProcessName=Finder.exe
        [SysInfoAlias]
        Measure=Plugin
        Plugin=SysInfo
        SysInfoType=USER_NAME
        """, system: system, host: host, clock: .fixed(Date(timeIntervalSince1970: 1_798_761_598), timeZone: shanghai))
        defer { skin.close(); withExtendedLifetime(host) {} }
        t.equal(skin.measures.map(\.name), ["Calc", "Loop", "Time", "Uptime", "Disk", "Process", "SysInfo", "Power", "ProcessAlias", "SysInfoAlias"])
        skin.update()
        t.equal(skin.measures.map(\.value), [5, 0, 13_443_263_998, 3725, 250, 1, 1280, 3200, 1, 0])
        t.equal(skin.measure(named: "Disk")?.rawString, "Macintosh HD")
        t.equal(skin.measure(named: "SysInfoAlias")?.rawString, "tester")
        for measure in skin.measures { t.check(measure.skin === skin) }
        for ((cls, type), measure) in zip(classes, skin.measures.prefix(8)) {
            t.check(ObjectIdentifier(Swift.type(of: measure)) == ObjectIdentifier(cls))
            let legacy = cls.init(name: "Direct\(measure.name)", section: measure.own, skin: skin, type: type)
            legacy.readOptionsIfNeeded(); legacy.performUpdate()
            t.check(legacy.skin === skin)
            t.equal(legacy.value, measure.value)
            t.equal(legacy.rawString, measure.rawString)
        }
        t.equal(skin.measure(named: "ProcessAlias")?.type, "process")
        t.equal(skin.measure(named: "SysInfoAlias")?.type, "sysinfo")
        let ordinaryStamp = (skin.measure(named: "Time") as? TimeMeasure)?.timestamp
        t.equal(ordinaryStamp, 13_443_263_998)
        let sample = MeasureValueOverride(); sample.frozenTime = Date(timeIntervalSince1970: 1_798_761_600)
        skin.measureValues = sample
        skin.measure(named: "Time")?.performUpdate()
        t.equal(skin.measure(named: "Time")?.value, 13_443_264_000)
        t.equal(skin.resolve("[Time:TimeStamp]", in: nil, sectionVariables: true), "13443263998", "the real resolver still reads the old stored timestamp after frozen show")
    }
}

private func runContextRegistryTests(_ t: TestRunner) {
    t.suite("Engine: context registry: live wallpaper keeps numeric rules and independent input state") {
        let system = ContextBuiltinSystem()
        system.wallpaper = "20"
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-registry-live"), system: system)
        let node = try extendedNode(RegistryMeasure.self, "Wallpaper", "registry", [
            ("RegHKey", "HKCU"), ("RegKey", "Control Panel/Desktop/"), ("RegValue", " WALLPAPER "),
            ("MinValue", "0"), ("MaxValue", "100"), ("AverageSize", "2"), ("InvertMeasure", "1"),
        ], in: context)
        t.equal(system.calls, [], "construction does not read the data source")
        t.check(!node.valueUnavailable)
        node.readOptionsIfNeeded()
        t.equal(system.calls, ["desktopPicture"])
        t.equal(context.services, [], "reading options does not note a live update")
        node.performUpdate()
        t.equal(node.value, 80)
        t.equal(node.rawString, "20")
        t.equal(system.calls, ["desktopPicture", "desktopPicture"])
        system.wallpaper = "40"
        node.performUpdate()
        t.equal(node.value, 70, "the existing average then inversion pipeline runs once")
        t.equal(node.stringValue, "40", "a numeric string retains its text independently of numeric rules")
        t.equal(node.runtimeSnapshot.average, SkinRuntimeState.Average(samples: [20, 40], next: 0))
        t.equal(context.services, [.system])
        system.wallpaper = nil
        node.performUpdate()
        t.check(node.valueUnavailable)
        t.equal(node.rawString, "")
        t.equal(context.issues.count, 1)
        node.performUpdate()
        t.equal(context.issues.count, 1, "the existing issue set deduplicates unavailable live values")
        system.wallpaper = ""
        node.performUpdate()
        t.check(!node.valueUnavailable, "an available empty value differs from an unavailable value")
        system.wallpaper = "/fixture/图片😀.heic"
        node.performUpdate()
        t.equal(node.stringValue, "/fixture/图片😀.heic")
        t.check(!node.valueUnavailable)
        t.equal(system.calls, Array(repeating: "desktopPicture", count: 7))
        t.equal(node.updateCount, 6)
        node.setPaused(true); node.performUpdate()
        node.setPaused(false); node.setDisabled(true); node.performUpdate()
        t.equal(system.calls.count, 7, "paused and disabled nodes do not sample")
        t.equal(node.updateCount, 6)
        t.equal(node.value, 0)
        t.equal(context.services, [.system])
    }

    t.suite("Engine: context registry: static values cache and option changes keep their original behavior") {
        // The existing machine-facts cache also reads OS metadata. Reset it around this isolated source control,
        // as the Registry threading suite does; this is not a claim that all machine facts are injected.
        RegistryMeasure.Facts.forget()
        defer { RegistryMeasure.Facts.forget() }
        let system = ContextBuiltinSystem()
        system.values.sysInfoAnswers["OS_PRODUCT_NAME"] = (0, "macOS Context")
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-registry-static"), system: system)
        let version = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion"
        let environment = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment"
        let product = try extendedNode(RegistryMeasure.self, "Product", "registry", [
            ("RegHKey", "HKLM"), ("RegKey", version), ("RegValue", "ProductName"),
        ], in: context)
        product.readOptionsIfNeeded()
        t.equal(system.calls.filter { $0 == "sysInfo:OS_PRODUCT_NAME:" }.count, 1)
        system.values.sysInfoAnswers["OS_PRODUCT_NAME"] = (0, "Changed source")
        system.resetCalls()
        product.performUpdate(); product.performUpdate()
        t.equal(product.stringValue, "macOS Context")
        t.equal(system.calls, [], "an unchanged static measure uses its cached result")
        let cores = try extendedNode(RegistryMeasure.self, "Cores", "registry", [
            ("RegHKey", "HKLM"), ("RegKey", environment), ("RegValue", "NUMBER_OF_PROCESSORS"),
        ], in: context)
        let frequency = try extendedNode(RegistryMeasure.self, "Frequency", "registry", [
            ("RegHKey", "HKLM"), ("RegKey", "HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0"), ("RegValue", "~MHz"),
        ], in: context)
        let names = try extendedNode(RegistryMeasure.self, "Names", "registry", [
            ("RegHKey", "HKLM"), ("RegKey", environment), ("OutputType", "ValueList"), ("OutputDelimiter", "|"),
        ], in: context)
        let children = try extendedNode(RegistryMeasure.self, "Children", "registry", [
            ("RegHKey", "HKLM"), ("RegKey", "HARDWARE\\DESCRIPTION\\System\\CentralProcessor"),
            ("OutputType", "SubKeyList"), ("OutputDelimiter", "|"),
        ], in: context)
        for node in [cores, frequency, names, children] { node.readOptionsIfNeeded(); node.performUpdate() }
        t.equal(cores.value, 8)
        t.equal(cores.rawString, "8")
        t.equal(frequency.value, 3200)
        t.equal(frequency.rawString, nil, "a numeric registry value has no raw string")
        t.equal(names.stringValue, "NUMBER_OF_PROCESSORS|PROCESSOR_ARCHITECTURE|PROCESSOR_IDENTIFIER")
        t.equal(children.stringValue, "0|1|2|3|4|5|6|7")
        product.overrides["regvalue"] = "InstallationType"
        product.needsOptionRead = true
        product.readOptionsIfNeeded(); product.performUpdate()
        t.equal(product.stringValue, "Client", "changed options invalidate only the node result cache")
        names.overrides["outputdelimiter"] = ";"
        names.needsOptionRead = true
        names.readOptionsIfNeeded(); names.performUpdate()
        t.equal(names.stringValue, "NUMBER_OF_PROCESSORS;PROCESSOR_ARCHITECTURE;PROCESSOR_IDENTIFIER")
        product.overrides["regvalue"] = "UnemulatedContextValue"
        product.needsOptionRead = true
        product.readOptionsIfNeeded(); product.performUpdate()
        t.check(product.valueUnavailable)
        t.equal(product.value, 0)
        t.equal(product.rawString, "")
        t.equal(context.issues.count, 1)
        system.resetCalls(); product.performUpdate()
        t.equal(system.calls, [], "a missing static result is cached too")
        t.equal(context.issues.count, 1)
        t.equal(context.services, Array(repeating: .system, count: 5))
    }

    t.suite("Engine: context registry: exact factory preserves aliases and legacy required construction") {
        let system = ContextBuiltinSystem()
        system.wallpaper = "/fixture/wallpaper.png"
        let context = try IndependentSectionContext(directory: t.temporaryDirectory("context-registry-factory"), system: system)
        t.check(makeContextBuiltinMeasure(ContextFactoryChild.self, name: "Custom", section: constructionSection("Custom", []),
                                         context: context, type: "registry") == nil)
        // Unique aliases preserve the global canonical Registry registration and custom-class precedence.
        MeasureRegistry.registerMeasure("ContextFactoryRegistryAlias", RegistryMeasure.self)
        MeasureRegistry.registerMeasure("ContextFactoryRegistryOverride", ContextFactoryChild.self)
        let host = EnvironmentHost()
        let skin = try extendedConsumerSkin(t, """
        [Rainmeter]
        Update=-1
        [Wallpaper]
        Measure=Registry
        RegKey=Control Panel\\Desktop
        RegValue=Wallpaper
        [Alias]
        Measure=ContextFactoryRegistryAlias
        RegKey=Control Panel\\Desktop
        RegValue=Wallpaper
        [Custom]
        Measure=ContextFactoryRegistryOverride
        """, system: system, host: host, clock: context.skinClock)
        defer { skin.close(); withExtendedLifetime(host) {} }
        skin.update()
        guard let selected = skin.measure(named: "Wallpaper") as? RegistryMeasure,
              let alias = skin.measure(named: "Alias") as? RegistryMeasure,
              let custom = skin.measure(named: "Custom") as? ContextFactoryChild else {
            throw SectionConstructionError.unexpectedKernel
        }
        t.check(selected.skin === skin)
        t.check(alias.skin === skin)
        t.equal(selected.stringValue, "/fixture/wallpaper.png")
        t.equal(alias.stringValue, selected.stringValue)
        t.equal(alias.type, "contextfactoryregistryalias")
        t.equal(custom.constructorTrace, ["base:contextfactoryregistryoverride", "child:contextfactoryregistryoverride"])
        t.equal(custom.value, 456)
        let legacy = RegistryMeasure(name: "Direct", section: selected.own, skin: skin, type: "registry")
        legacy.readOptionsIfNeeded(); legacy.performUpdate()
        t.check(legacy.skin === skin)
        t.equal(legacy.value, selected.value)
        t.equal(legacy.rawString, selected.rawString)
        system.wallpaper = "/fixture/new.heic"
        skin.update(); legacy.performUpdate()
        t.equal(selected.stringValue, "/fixture/new.heic")
        t.equal(alias.rawString, legacy.rawString)
    }
}
