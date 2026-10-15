import Darwin
import Foundation

/// An owner for the qualified compatibility kernels. The program remains a value; kernels borrow this owner,
/// and its timer borrows it weakly. No Skin, host adapter or escaping resolver is retained here.
package final class RainmeterProgramRuntime: SectionContext, LayoutSource, SceneProjectionSource, HitMapSource, TickTarget, BackgroundWorkOwner {
    package let program: RainmeterProgram
    package let executor: SkinExecutor
    let skinClock: SkinClock
    let system: SystemDataSource
    let sideEffects: SideEffects
    private var environment: SkinEnvironment
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
    let random: SkinRandom
    var settings: SkinSettings { program.window.settings }
    var sources: IniSourceMap { program.sourceMap }
    var counter: Int { updateCount }
    var clock: () -> TimeInterval { skinClock.uptime }
    var locale: Locale { environment.locale }
    var directory: URL { program.fileURL.deletingLastPathComponent() }
    var skinsDirectory: URL { program.skinsDirectory }
    var resourcesDirectory: URL { program.resourcesDirectory }
    var runsInVirtualTime: Bool { executor is VirtualTimeExecutor }
    var measureValues: MeasureValueOverride? { nil }
    var host: SkinHost? { nil }
    var rainmeterSection: RainmeterSection? { nil }
    var hitMapReadsMeasures = false
    package var updateMilliseconds: Int { settings.update }

    /// A completed engine update, still on the owner. The App frame producer subscribes weakly.
    package var didUpdate: (() -> Void)?
    package var isPaused: Bool { scheduler.isPaused }

    /// The verifier keeps its original deterministic convenience entry.
    package convenience init(program: RainmeterProgram, executor: VirtualTimeExecutor, clock: SkinClock,
                             environment: SkinEnvironment, system: SystemDataSource, effects: RecordingSideEffects,
                             text: (any RainmeterTextMeasuring)?) throws {
        try self.init(program: program, executor: executor, clock: clock, environment: environment,
                      system: system, effects: effects, random: SkinRandom(seed: 1), text: text)
    }

    /// Services and scheduling belong to the caller's owner; no verifier executor or recording is required.
    package init(program: RainmeterProgram, executor: SkinExecutor, clock: SkinClock,
                 environment: SkinEnvironment, system: SystemDataSource, effects: SideEffects,
                 random: SkinRandom, text: (any RainmeterTextMeasuring)?) throws {
        self.program = program
        self.executor = executor
        skinClock = clock
        self.environment = environment
        self.system = system
        sideEffects = effects
        self.random = random
        textService = text
        assertOwned(#function)
        for section in program.sections { sectionIndex[section.name.lowercased()] = section.ini }
        variables = VariableResolver.resolveDefinitions(sectionIndex["variables"]?.entries ?? [],
                                                        builtins: program.staticBuiltins)
        for section in program.sections {
            let ini = section.ini
            switch section.kernel {
            case .time, .calc, .cpu, .memory, .physicalmemory, .swapmemory, .uptime, .netin, .netout, .nettotal, .process, .freediskspace, .sysinfo, .quoteplugin, .powerplugin:
                guard let kernel = section.kernel, let selectedClass = kernel.measureClass,
                      let node = makeContextBuiltinMeasure(selectedClass, name: section.name, section: ini,
                                                           context: self, type: kernel.rawValue) else {
                    throw RainmeterProgramError.inconsistentFrozenInput
                }
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
        didUpdate?()
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
    /// Published host facts, consumed on the owner; no window or AppKit query enters the engine.
    package func takeEnvironment(_ environment: SkinEnvironment) {
        assertOwned(#function)
        guard !isClosed else { return }
        self.environment = environment
    }
    package func pause() {
        assertOwned(#function)
        guard !isClosed else { return }
        scheduler.pause()
    }
    package func resume(updateNow: Bool) throws {
        assertOwned(#function)
        try checkOpen()
        scheduler.resume(updateNow: updateNow, target: self)
        // An immediate update can reject a service synchronously. Do not leave its rearmed timer running.
        if let failure { scheduler.cancel(); throw failure }
    }
    package func wake() throws {
        assertOwned(#function)
        try checkOpen()
        scheduler.wake(target: self)
        if let failure { scheduler.cancel(); throw failure }
    }
    package func close() {
        assertOwned(#function)
        guard !isClosed else { return }
        isClosed = true
        scheduler.cancel()
        didUpdate = nil
        for measure in orderedMeasures { (measure as? PluginLifecycle)?.skinWillClose() }
        for meter in meters { (meter as? PluginLifecycle)?.skinWillClose() }
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
    func readablePath(_ path: String) -> String { sideEffects.readablePath(path) }
    func quoteRead(path: String, separator: String, subfolders: Bool, filter: WildcardFilter)
        -> () -> Result<[String], QuoteMeasure.ReadError> {
        // Freeze the authorized spelling before enqueueing, including existing in-tree symlinks.
        // No descriptor or contents are opened until production; init never calls this method.
        let root = Self.quotePhysicalPath(program.resourcesDirectory.deletingLastPathComponent().path)
        let mapped = readablePath(path)
        let target = Self.quotePhysicalPath(mapped)
        let allowedRoot: String
        if mapped == path {
            allowedRoot = root
        } else if let sandbox = sideEffects.fileSandbox {
            allowedRoot = Self.quotePhysicalPath(sandbox.directory.path)
        } else {
            return { .failure(.unreadable(path)) }
        }
        let base = allowedRoot
        guard target == base || target.hasPrefix(base + "/") else {
            return { .failure(.unreadable(path)) }
        }
        return { Self.readQuoteFile(target: target, displayPath: path, separator: separator) }
    }

    /// Foundation can preserve the /var alias on macOS. Descriptor walks need its physical
    /// spelling, including the nearest existing ancestor for a missing file.
    private static func quotePhysicalPath(_ path: String) -> String {
        var candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        var suffix: [String] = []
        while true {
            if let resolved = Darwin.realpath(candidate, nil) {
                defer { free(resolved) }
                let base = String(cString: resolved)
                return suffix.reversed().reduce(base) { $0 + "/" + $1 }
            }
            guard candidate != "/" else { return path }
            let url = URL(fileURLWithPath: candidate)
            suffix.append(url.lastPathComponent)
            candidate = url.deletingLastPathComponent().path
        }
    }

    /// Walk from / using directory descriptors, refusing symlinks at *every* component, including
    /// the package/sandbox root and its ancestors. Once opened, read that same regular-file fd.
    /// Renames cannot redirect an acquired directory fd; a replacement link is never followed.
    /// Existing in-tree links were canonicalized before enqueueing, not re-resolved here.
    private static func readQuoteFile(target: String, displayPath: String, separator: String)
        -> Result<[String], QuoteMeasure.ReadError> {
        let components = target.split(separator: "/").map(String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            return .failure(.unreadable(displayPath))
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.unreadable(displayPath)) }
        defer { Darwin.close(fd) }
        for (index, component) in components.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = component.withCString { Darwin.openat(fd, $0, flags) }
            guard next >= 0 else {
                return .failure(errno == ENOENT ? .missing(displayPath) : .unreadable(displayPath))
            }
            Darwin.close(fd)
            fd = next
        }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { return .failure(.unreadable(displayPath)) }
        if (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) {
            return .failure(.directoryNotAdmitted(displayPath))
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failure(.unreadable(displayPath))
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                return .failure(.unreadable(displayPath))
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return .success(QuoteMeasure.split(TextDecoding.decode(data), separator: separator))
    }

    func absolutePath(_ raw: String, relativeTo base: URL?) -> String { reject("absolutePath"); return "" }
    func imageFilePath(_ name: String, imagePath: String) -> String { reject("imageFilePath"); return "" }
    func allowsWebParserFileAccess(_ path: String) -> Bool { reject("WebParser file access"); return false }
    func formulaValue(of identifier: String, from section: SkinSection?) -> Double? {
        // Read at the kernel's original evaluation point: forward and self references see their previous value.
        measureIndex[identifier.lowercased()]?.value
    }
    func noteService(_ kind: BackgroundWorkKind) {
        guard kind == .system || kind == .battery else { reject("service \(kind)"); return }
        guard let virtual = executor as? VirtualTimeExecutor else { return }
        let scripted = (system as? ScriptedSystemData)?.gives(kind) ?? false
        virtual.background.noteService(kind, config: program.config, scripted: scripted)
    }
    func execute(_ actionText: String, from section: SkinSection?) { reject("action") }
    func executePointerAction(_ action: String, from section: SkinSection, x: Double, y: Double,
                              relativeToSkin: Bool) { reject("pointer action") }
    func async(_ work: @escaping () -> Void) { reject("async") }
    func receiveBackgroundWork(_ work: () -> Void, orElse dropped: (() -> Void)?) {
        assertOwned(#function)
        guard !isClosed, failure == nil else { dropped?(); return }
        // A service result is not an extra tick: meters consume it on their next ordinary update.
        work()
    }

    func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void,
                            orElse dropped: ((T) -> Void)?) {
        assertOwned(#function)
        guard !isClosed, failure == nil else { return }
        guard job.kind == .quote else { reject("background \(job.kind)"); return }
        let tree = program.resourcesDirectory.deletingLastPathComponent()
        guard let reads = job.reads, RainmeterProgram.allowsQuoteRead(reads, root: tree) else {
            reject("Quote read outside root config"); return
        }
        BackgroundWorkDelivery.start(job, hop: SkinHop(owner: self, executor: executor), executor: executor,
                                     config: program.config, tree: tree, then: completion, orElse: dropped)
    }
}
