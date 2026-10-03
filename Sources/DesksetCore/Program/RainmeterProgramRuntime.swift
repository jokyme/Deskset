import Foundation

/// An owner for the qualified compatibility kernels. The program remains a value; kernels borrow this owner,
/// and its timer borrows it weakly. No Skin, host adapter or escaping resolver is retained here.
package final class RainmeterProgramRuntime: SectionContext, LayoutSource, SceneProjectionSource, HitMapSource, TickTarget {
    package let program: RainmeterProgram
    package let executor: SkinExecutor
    let skinClock: SkinClock
    let system: SystemDataSource
    let sideEffects: SideEffects
    private let environment: SkinEnvironment
    private let textService: (any RainmeterTextMeasuring)?
    private let layout = LayoutDriver()
    private let projector = SceneProjector()
    private let scheduler = TickScheduler()
    private var sectionIndex: [String: IniSection] = [:]
    private var measureIndex: [String: Measure] = [:]
    private var meterIndex: [String: Meter] = [:]
    private var logged: Set<String> = []
    private var updating = 0
    private var snapshotGeneration: UInt64 = 0
    private(set) var optionsLoaded = false
    private(set) var meters: [Meter] = []
    private(set) var orderedMeasures: [Measure] = []
    private(set) var variables: [String: String] = [:]
    package private(set) var updateCount = 0
    package private(set) var width = 0.0
    package private(set) var height = 0.0
    package private(set) var isClosed = false
    package private(set) var failure: RainmeterProgramError?
    package private(set) var logs: [String] = []
    private var issues: Set<String> = []
    let random = SkinRandom(seed: 1)
    var settings: SkinSettings { program.window.settings }
    var sources: IniSourceMap { program.sourceMap }
    var counter: Int { updateCount }
    var clock: () -> TimeInterval { skinClock.uptime }
    var locale: Locale { environment.locale }
    var directory: URL { program.fileURL.deletingLastPathComponent() }
    var skinsDirectory: URL { program.skinsDirectory }
    var resourcesDirectory: URL { program.resourcesDirectory }
    var runsInVirtualTime: Bool { true }
    var measureValues: MeasureValueOverride? { nil }
    var host: SkinHost? { nil }
    var rainmeterSection: RainmeterSection? { nil }
    var hitMapReadsMeasures = false
    package var updateMilliseconds: Int { settings.update }

    package init(program: RainmeterProgram, executor: VirtualTimeExecutor, clock: SkinClock,
                 environment: SkinEnvironment, system: SystemDataSource, effects: RecordingSideEffects,
                 text: (any RainmeterTextMeasuring)?) throws {
        self.program = program
        self.executor = executor
        skinClock = clock
        self.environment = environment
        self.system = system
        sideEffects = effects
        textService = text
        assertOwned(#function)
        for section in program.sections { sectionIndex[section.name.lowercased()] = section.ini }
        variables = VariableResolver.resolveDefinitions(sectionIndex["variables"]?.entries ?? [],
                                                        builtins: program.staticBuiltins)
        for section in program.sections {
            let ini = section.ini
            switch section.kernel {
            case .time:
                let node = TimeMeasure(name: section.name, section: ini, context: self, type: "time")
                orderedMeasures.append(node); measureIndex[section.name.lowercased()] = node
            case .string:
                let node = StringMeter(name: section.name, section: ini, context: self, type: "string")
                meters.append(node); meterIndex[section.name.lowercased()] = node
            case .image:
                let node = ImageMeter(name: section.name, section: ini, context: self, type: "image")
                meters.append(node); meterIndex[section.name.lowercased()] = node
            case nil: break
            }
        }
        layout.resetFrameReadiness()
        for measure in orderedMeasures { measure.readOptionsIfNeeded() }
        for meter in meters where meter.needsOptionRead { meter.readOptionsIfNeeded() }
        optionsLoaded = true
        // The admission profile excludes section references, but retain the kernel's normal first-read rule.
        for measure in orderedMeasures where measure.mentionsSectionVariables && !measure.dynamicVariables {
            measure.needsOptionRead = true
        }
        for meter in meters where meter.mentionsSectionVariables && !meter.dynamicVariables { meter.needsOptionRead = true }
        try checkOpen()
    }

    package func update() throws {
        assertOwned(#function)
        try checkOpen()
        guard updating < Skin.maxUpdateDepth else {
            logOnce("!Update inside an update was ignored (would loop)", level: .warning)
            return
        }
        updating += 1
        defer { updating -= 1 }
        for measure in orderedMeasures where measure.consumeUpdateTick() {
            measure.readOptionsIfNeeded()
            measure.performUpdate()
            try checkOpen()
        }
        guard layout.updateMeterPass(in: self, updateMeter: { meter in
            meter.readOptionsIfNeeded()
            meter.updateMeter()
            meter.noteDrawChange()
        }) else { try checkOpen(); return }
        try checkOpen()
        updateCount += 1
        if let size = layout.windowSize(in: self, backgroundSize: { nil }) {
            width = size.width
            height = size.height
        }
    }

    package func project(environment: SceneEnvironment) throws -> WidgetScene {
        assertOwned(#function)
        try checkOpen()
        return projector.project(source: self, environment: environment)
    }

    package func startTimer() throws {
        assertOwned(#function)
        try checkOpen()
        scheduler.startTimer(for: self)
    }
    package func close() {
        assertOwned(#function)
        scheduler.cancel()
        isClosed = true
    }
    package func updateForTick() {
        do { try update() }
        catch let error as RainmeterProgramError { failure = error; scheduler.cancel() }
        catch { reject("update: \(error)") }
    }
    package func notifySystemWake() {}
    private func checkOpen() throws {
        if let failure { throw failure }
        if isClosed { throw RainmeterProgramError.closed }
    }
    private func reject(_ service: String) {
        if failure == nil { failure = .unexpectedService(service) }
        scheduler.cancel()
    }

    func measure(named name: String) -> Measure? { measureIndex[name.lowercased()] }
    func meter(named name: String) -> Meter? { meterIndex[name.lowercased()] }
    func styleSection(named name: String) -> IniSection? { sectionIndex[name.lowercased()] }
    func styleValues(named name: String) -> [String: String]? { styleSection(named: name).map(OptionStack.index) }
    private func resolver(in section: SkinSection?) -> VariableResolver {
        VariableResolver(variableLookup: { [unowned self] name in
            name.lowercased() == "currentsection" ? (section?.name ?? "") : self.variables[name.lowercased()]
        })
    }
    func resolve(_ text: String, in section: SkinSection?, sectionVariables: Bool) -> String {
        resolver(in: section).resolve(text)
    }
    func resolveStandardVariables(_ text: String, in section: SkinSection?) -> String {
        resolver(in: section).resolveStandardVariables(text)
    }
    func mentionsSectionVariable(_ text: String) -> Bool { false } // Rejected before any kernel is constructed.
    func textSize(_ text: String, style: TextStyle, wrapWidth: Double?) -> (width: Double, height: Double)? {
        textService?.measure(text, style: style, wrapWidth: wrapWidth, cycle: updateCount)
            .map { ($0.width, $0.height) }
    }
    func currentEnvironment() -> SkinEnvironment { environment }
    func projectionGlass(_ source: SceneProjector.GlassSource) -> [GlassRegion] { [] } // Glass is outside this profile.
    func shownGlassRegion(of meter: Meter) -> GlassRegion? { nil }
    func makeHitMap() -> SkinHitMap {
        assertOwned(#function)
        return buildHitMap()
    }
    func noteSnapshotChange() { snapshotGeneration &+= 1 }
    func assertOwned(_ entry: StaticString) { precondition(executor.isCurrent, "\(entry) called off the program owner") }
    func log(_ message: String, level: SkinLogLevel) { logs.append("\(level.rawValue): \(message)") }
    func logOnce(_ message: String, level: SkinLogLevel) {
        if logged.insert(message).inserted { log(message, level: level) }
    }
    func addIssue(_ issue: String) { issues.insert(issue) }
    func removeIssue(_ issue: String) { issues.remove(issue) }
    func readablePath(_ path: String) -> String { path }
    func absolutePath(_ raw: String, relativeTo base: URL?) -> String { reject("absolutePath"); return "" }
    func imageFilePath(_ name: String, imagePath: String) -> String { reject("imageFilePath"); return "" }
    func allowsWebParserFileAccess(_ path: String) -> Bool { reject("WebParser file access"); return false }
    func formulaValue(of identifier: String, from section: SkinSection?) -> Double? {
        reject("formula identifier \(identifier)"); return nil
    }
    func noteService(_ kind: BackgroundWorkKind) { reject("service \(kind)") }
    func execute(_ actionText: String, from section: SkinSection?) { reject("action") }
    func executePointerAction(_ action: String, from section: SkinSection, x: Double, y: Double,
                              relativeToSkin: Bool) { reject("pointer action") }
    func async(_ work: @escaping () -> Void) { reject("async") }
    func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void,
                            orElse dropped: ((T) -> Void)?) { reject("background \(job.kind)") }
}
