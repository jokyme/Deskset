import Foundation

// The seam for a skin's background work (the runtime design, "background completion points"): every piece of work a
// measure starts off the skin's thread — a file read, a folder scan, a ping, a child process, a web request, a sensor
// listing, an image analysis — goes through `Skin.startBackground`, and every service that calls a skin back goes
// through `Skin.backgroundHop`. The engine names what each one is (`BackgroundWorkKind`).
//
// Live (every executor but `VirtualTimeExecutor`): exactly what the engine did before — the work runs on the queue or
// the transport it always ran on, and its result comes back through `SkinHop.post`.
//
// Virtual time (`VirtualTimeExecutor`): no real background thread when there is a fake. A fake's completion is an
// ordinary piece of work in the executor's queue, due at the next `runUntilIdle()` unless the fake gives a delay; a
// fixture fake does the work itself (it only reads the Mac's files) when that piece of work runs, a scripted fake turns
// a given value into the result. Work without a fake runs for real, as in live mode, and is reported: the skin that
// started it cannot be verified.

// MARK: - Kinds

/// Each place where a skin's background work comes back.
public enum BackgroundWorkKind: String, CaseIterable, Sendable {
    /// QuotePlugin reads a file or a folder.
    case quote
    /// FolderInfo scans a folder.
    case folderInfo
    /// FileView lists a folder.
    case fileViewListing
    /// FileView asks the system for a file's icon and saves it.
    case fileViewIcon
    /// PingPlugin sends an ICMP echo.
    case ping
    /// RunCommand's program runs until it exits.
    case runCommandProcess
    /// RunCommand decodes the program's output and saves OutputFile.
    case runCommandOutput
    /// WebParser reads its resource (a web page or a local file) and parses it.
    case webParserPage
    /// WebParser downloads a file (`Download=1`).
    case webParserDownload
    /// MacWeather hears from the shared weather service.
    case weather
    /// MacSun hears from the shared weather service.
    case sun
    /// MacSensors' `List` reads every sensor.
    case sensorList
    /// ResMon looks up processes by name.
    case resMon
    /// Chameleon reads and analyses an image (a file or the desktop picture).
    case desktopImage
    /// RecycleManager reads the Trash's item count and size (a shared service; `.service` when the host gave it a
    /// fixture, such as `--data`'s `trash`).
    case trash

    // Shared services a measure reads directly at its updates (`Measure.liveInputs`, noted on its first update): not
    // background work of the skin, but inputs that differ from one run to the next unless the host fakes the service
    // (`.service`) or the skin's system data is scripted (`ScriptedSystemData`, for the first three).

    /// The Mac's system data: CPU, memory, network, disks, uptime, processes, SysInfo (`SystemDataSource`).
    case system
    /// The battery (PowerPlugin).
    case battery
    /// Hardware sensors: temperatures, fans, power (MacSensors, CoreTemp, SpeedFan, MSIAfterburner).
    case sensors
    /// A media player (NowPlaying, iTunes, WebNowPlaying: the NowPlaying center).
    case nowPlaying
    /// The Mac's audio levels (AudioLevel).
    case audio
    /// The Mac's audio devices and volume (Win7Audio, AppVolume).
    case volume
    /// The Wi-Fi interface (WiFiStatus).
    case wifi
    /// The front window (GetActiveTitle, IsFullScreen).
    case frontWindow
    /// The Mac's system colours (SysColor).
    case systemColors

    /// What it does, for reports.
    public var summary: String {
        switch self {
        case .quote: return "QuotePlugin reads a file or folder"
        case .folderInfo: return "FolderInfo scans a folder"
        case .fileViewListing: return "FileView lists a folder"
        case .fileViewIcon: return "FileView asks the system for a file's icon"
        case .ping: return "PingPlugin pings a host over the network"
        case .runCommandProcess: return "RunCommand runs a program"
        case .runCommandOutput: return "RunCommand saves the program's output"
        case .webParserPage: return "WebParser reads its resource"
        case .webParserDownload: return "WebParser downloads a file"
        case .weather: return "MacWeather hears from the weather service"
        case .sun: return "MacSun hears from the weather service"
        case .sensorList: return "MacSensors lists the Mac's sensors"
        case .resMon: return "ResMon looks up processes by name"
        case .desktopImage: return "Chameleon reads and analyses an image"
        case .trash: return "RecycleManager reads the Trash"
        case .system: return "the skin reads the Mac's system data"
        case .battery: return "PowerPlugin reads the battery"
        case .sensors: return "the skin reads the Mac's sensors"
        case .nowPlaying: return "the skin reads a media player"
        case .audio: return "AudioLevel reads the Mac's audio"
        case .volume: return "the skin reads the Mac's audio devices and volume"
        case .wifi: return "WiFiStatus reads the Wi-Fi"
        case .frontWindow: return "the skin reads the front window"
        case .systemColors: return "SysColor reads the Mac's colours"
        }
    }
}

// MARK: - Fakes

/// A scripted result for a piece of background work (virtual time). Each kind reads the form that suits it: Ping a
/// number of milliseconds, WebParser the bytes or text of the resource, MacSensors' list its lines; `failure` is the
/// work failing (Ping: no reply; WebParser: no connection).
public enum BackgroundFakeValue: Equatable, Sendable {
    case number(Double)
    case text(String)
    case data(Data)
    case lines([String])
    case failure(String)

    public var number: Double? {
        switch self {
        case .number(let v): return v
        case .text(let s): return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    /// The bytes of `data`, or `text` as UTF-8.
    public var bytes: Data? {
        switch self {
        case .data(let d): return d
        case .text(let s): return Data(s.utf8)
        default: return nil
        }
    }

    /// `lines`, or `text` split into lines.
    public var lines: [String]? {
        switch self {
        case .lines(let l): return l
        case .text(let s): return s.components(separatedBy: .newlines)
        default: return nil
        }
    }

    public var failureMessage: String? {
        if case .failure(let m) = self { return m }
        return nil
    }
}

/// One request for background work, as a script sees it.
public struct BackgroundWorkRequest: Equatable, Sendable {
    public let kind: BackgroundWorkKind
    /// What it is about: a path, a host, a URL, a command, a process name.
    public let subject: String
    /// The skin that asked.
    public let config: String
}

/// How a kind of background work is faked in virtual time.
public struct BackgroundFake {
    public enum Source {
        /// The work itself, done on the executor when its completion is due — for work that only reads the Mac's files
        /// (the skin's fixtures): QuotePlugin, FolderInfo, FileView's listing, a WebParser `file://` resource.
        case fixture
        /// This value for every request.
        case value(BackgroundFakeValue)
        /// A value per request, decided when the request is made (nil: no fake for that one).
        case script((BackgroundWorkRequest) -> BackgroundFakeValue?)
        /// The host put a fake of the service itself in place (the weather service without network, a Trash given as
        /// data): what it tells the skins does not depend on the outside world. Background work of that kind runs as
        /// it would (against the fake service) and counts as faked; its result still comes back as real work does,
        /// so `settle` waits for it.
        case service
    }

    public var source: Source
    /// Virtual seconds between the request and its completion (0: the next `runUntilIdle`).
    public var delay: TimeInterval

    public init(_ source: Source, delay: TimeInterval = 0) {
        self.source = source
        self.delay = delay.isFinite ? max(delay, 0) : 0
    }

    public static let fixture = BackgroundFake(.fixture)
    public static let service = BackgroundFake(.service)

    public static func value(_ value: BackgroundFakeValue, delay: TimeInterval = 0) -> BackgroundFake {
        BackgroundFake(.value(value), delay: delay)
    }

    public static func script(delay: TimeInterval = 0,
                              _ answer: @escaping (BackgroundWorkRequest) -> BackgroundFakeValue?) -> BackgroundFake {
        BackgroundFake(.script(answer), delay: delay)
    }
}

/// What a virtual run did with a kind of background work of a skin.
public struct BackgroundWorkReport: Equatable, Sendable, CustomStringConvertible {
    public let kind: BackgroundWorkKind
    public let config: String
    /// The first request's subject.
    public let subject: String
    /// A fake answered (false: the real work ran, so the skin cannot be verified).
    public let faked: Bool
    public let reason: String

    public var description: String {
        "\(config): \(kind.summary) (\(subject.isEmpty ? kind.rawValue : subject)): \(reason)"
    }
}

// MARK: - Jobs

/// A piece of background work as a measure starts it: how to do it for real, and how a fake can stand in for it.
public struct BackgroundJob<T> {
    public let kind: BackgroundWorkKind
    public let subject: String
    /// The real work: hands its result to the callback once, from any thread.
    let start: (@escaping (T) -> Void) -> Void
    /// The same work done at once, for a fixture fake; nil when it reaches beyond the Mac's files (the network, a
    /// program, the system's services, live system state).
    let inline: (() -> T)?
    /// Turns a scripted value into a result (any value: one that does not suit the kind is a failure); nil when the
    /// work cannot be scripted.
    let scripted: ((BackgroundFakeValue) -> T)?
    /// The file or folder the work reads, when it reads one: a fixture fake does the work itself only when that lies
    /// in the skin's own tree (its root config folder, with `@Resources`) or in a folder the host allowed
    /// (`VirtualBackgroundWork.allowFixtureReads`); anywhere else it is the user's live data (a Downloads folder a
    /// launcher lists), which differs from run to run, so the work runs for real and is reported.
    public var reads: String?

    /// Work that reports back through a callback of its own (a transfer, a process, a service).
    public init(_ kind: BackgroundWorkKind, subject: String,
                start: @escaping (@escaping (T) -> Void) -> Void,
                inline: (() -> T)? = nil, scripted: ((BackgroundFakeValue) -> T)? = nil, reads: String? = nil) {
        self.kind = kind
        self.subject = subject
        self.start = start
        self.inline = inline
        self.scripted = scripted
        self.reads = reads
    }

    /// Work done in one go on `queue`. `fixture`: it only reads the Mac's files (`reads`), so a fixture fake may do it
    /// on the executor.
    public init(_ kind: BackgroundWorkKind, subject: String, on queue: DispatchQueue, fixture: Bool,
                reads: String? = nil, scripted: ((BackgroundFakeValue) -> T)? = nil, _ work: @escaping () -> T) {
        self.init(kind, subject: subject, start: { deliver in queue.async { deliver(work()) } },
                  inline: fixture ? work : nil, scripted: scripted, reads: reads)
    }
}

// MARK: - Skin

extension Skin {
    /// Starts background work and hands its result to `completion` on the skin's executor, if the skin is still there
    /// then; otherwise `dropped` gets the result there instead (for what must not be left behind, such as a temporary
    /// file; it must not touch the skin). Call on the skin's own thread. Neither closure may hold the skin or its
    /// sections strongly: capture them weakly, as for `SkinHop`.
    public func startBackground<T>(_ job: BackgroundJob<T>, then completion: @escaping (T) -> Void,
                                   orElse dropped: ((T) -> Void)? = nil) {
        let hop = self.hop()
        if let virtual = executor as? VirtualTimeExecutor {
            virtual.background.start(job, hop: hop, config: config, tree: rootConfigDirectory, then: completion,
                                     orElse: dropped)
            return
        }
        job.start { result in
            hop.post({ completion(result) }, orElse: dropped.map { drop in { drop(result) } })
        }
    }

    /// The way back for a shared service that calls the skin back when it likes (MacWeather and MacSun hear from the
    /// weather service): `hop()`, noted as background work of `kind` in virtual time.
    public func backgroundHop(_ kind: BackgroundWorkKind) -> SkinHop {
        if let virtual = executor as? VirtualTimeExecutor { virtual.background.noteService(kind, config: config) }
        return self.hop()
    }

    /// In virtual time: the skin reads `kind` from a shared service (`Measure.liveInputs`). It counts as faked when the
    /// host put a fake of the service in place (`.service`) or, for the system data, the battery and the sensors, when
    /// the skin's system data gives them (`ScriptedSystemData`); otherwise the skin is reported as not verifiable.
    /// Live: nothing.
    public func noteService(_ kind: BackgroundWorkKind) {
        guard let virtual = executor as? VirtualTimeExecutor else { return }
        let scripted = (system as? ScriptedSystemData)?.gives(kind) ?? false
        virtual.background.noteService(kind, config: config, scripted: scripted)
    }

    /// Whether the skin runs in virtual time (`runInVirtualTime`): its measures then take what shared services tell
    /// them only as it comes back through the executor, never by reading the service's latest state, which a thread
    /// of the service changes at any moment.
    public var runsInVirtualTime: Bool { executor is VirtualTimeExecutor }
}

// MARK: - Virtual time

/// The background work of the skins of one `VirtualTimeExecutor` (its `background`): the fakes, a report of what each
/// skin did, and a wait for the real work of skins that have no fake. Thread-safe.
public final class VirtualBackgroundWork: @unchecked Sendable {
    /// What a new executor fakes: the work that only reads the Mac's files, done as a fixture. The rest has no fake
    /// until the host gives one.
    public static let defaultFakes: [BackgroundWorkKind: BackgroundFake] = [
        .quote: .fixture, .folderInfo: .fixture, .fileViewListing: .fixture, .runCommandOutput: .fixture,
        .webParserPage: .fixture, .webParserDownload: .fixture, .desktopImage: .fixture,
    ]

    weak var executor: VirtualTimeExecutor?
    private let condition = NSCondition()
    private var fakes = VirtualBackgroundWork.defaultFakes
    /// Folders a fixture may read besides the skin's own tree (`allowFixtureReads`), as `placeKey` gives them.
    private var fixtureRoots: [String] = []
    private var running = 0
    private var reportList: [BackgroundWorkReport] = []
    private var reported: Set<String> = []
    private var hooks: [() -> Void] = []

    init() {}

    /// The fake for `kind` (nil: the real work runs).
    public func fake(for kind: BackgroundWorkKind) -> BackgroundFake? {
        condition.lock()
        defer { condition.unlock() }
        return fakes[kind]
    }

    /// Fakes `kind` from now on (nil: the real work runs).
    public func setFake(_ fake: BackgroundFake?, for kind: BackgroundWorkKind) {
        condition.lock()
        fakes[kind] = fake
        condition.unlock()
    }

    /// Lets fixtures read the files in `folder` too (the folder of `--data`, a render's own settings folder): files
    /// the run brings along, not the user's.
    public func allowFixtureReads(under folder: URL) {
        let key = VirtualBackgroundWork.placeKey(folder.path)
        condition.lock()
        if !fixtureRoots.contains(key) { fixtureRoots.append(key) }
        condition.unlock()
    }

    /// Whether a fixture may read `path`: it lies in `tree` (the skin's root config folder) or an allowed folder.
    func fixtureMayRead(_ path: String, tree: URL?) -> Bool {
        let key = VirtualBackgroundWork.placeKey(path)
        condition.lock()
        var roots = fixtureRoots
        condition.unlock()
        if let tree { roots.append(VirtualBackgroundWork.placeKey(tree.path)) }
        return roots.contains { key == $0 || key.hasPrefix($0 + "/") }
    }

    /// `path` as file places are compared (links followed, compared the way the default Mac file system compares
    /// names).
    static func placeKey(_ path: String) -> String {
        let expanded = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
        var key = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
        while key.count > 1, key.hasSuffix("/") { key.removeLast() }
        return key
    }

    /// One line per skin and kind of work, in the order they were first met.
    public var reports: [BackgroundWorkReport] {
        condition.lock()
        defer { condition.unlock() }
        return reportList
    }

    /// The work that ran for real: the skins that started it cannot be verified.
    public var unverifiable: [BackgroundWorkReport] { reports.filter { !$0.faked } }

    /// Real work started and not yet handed back to the executor.
    public var outstanding: Int {
        condition.lock()
        defer { condition.unlock() }
        return running
    }

    /// Runs before every `settle` (a fake service's own drain: `WeatherService.drain`).
    public func addSettleHook(_ hook: @escaping () -> Void) {
        condition.lock()
        hooks.append(hook)
        condition.unlock()
    }

    /// Waits until the real work started so far has handed its result to the executor — for a condition, never for a
    /// fixed time — or `timeout` real seconds have passed. True when none is left. Faked work never needs it.
    @discardableResult
    public func settle(timeout: TimeInterval) -> Bool {
        condition.lock()
        let settleHooks = hooks
        condition.unlock()
        for hook in settleHooks { hook() }
        let deadline = Date(timeIntervalSinceNow: timeout.isFinite ? max(timeout, 0) : 0)
        condition.lock()
        defer { condition.unlock() }
        while running > 0 {
            if !condition.wait(until: deadline) { break }
        }
        return running == 0
    }

    func start<T>(_ job: BackgroundJob<T>, hop: SkinHop, config: String, tree: URL? = nil,
                  then completion: @escaping (T) -> Void, orElse dropped: ((T) -> Void)?) {
        let request = BackgroundWorkRequest(kind: job.kind, subject: job.subject, config: config)
        let fake = self.fake(for: job.kind)
        var produce: (() -> T)?
        var how = ""
        var reason = "no fake"
        switch fake?.source {
        case .fixture?:
            if let inline = job.inline {
                if let reads = job.reads, !reads.isEmpty, !fixtureMayRead(reads, tree: tree) {
                    reason = "it reads files outside the skin's own (\(reads)), which differ from one Mac to the next"
                } else {
                    produce = inline
                    how = "fixture: done on the executor from the files on disk"
                }
            } else {
                reason = "no fixture: it depends on the network, a program or the Mac's live state"
            }
        case .value(let value)?:
            if let scripted = job.scripted {
                produce = { scripted(value) }
                how = "scripted result"
            } else {
                reason = "it cannot be scripted"
            }
        case .script(let answer)?:
            if let scripted = job.scripted, let value = answer(request) {
                produce = { scripted(value) }
                how = "scripted result"
            } else {
                reason = job.scripted == nil ? "it cannot be scripted" : "no scripted result for this request"
            }
        case .service?:
            // Against the host's fake service: real work (its result comes back as real work does), but faked.
            report(request, faked: true, "the host's fake service")
            runReal(job, hop: hop, then: completion, orElse: dropped)
            return
        case nil:
            break
        }
        if let produce {
            report(request, faked: true, how)
            let deliver = { hop.post { completion(produce()) } }
            let delay = fake?.delay ?? 0
            if delay > 0, let executor {
                executor.async(after: delay, deliver)
            } else {
                deliver()
            }
            return
        }
        report(request, faked: false, reason + "; the real work ran")
        runReal(job, hop: hop, then: completion, orElse: dropped)
    }

    /// Starts `job` for real; `settle` waits until its result has been handed to the executor.
    private func runReal<T>(_ job: BackgroundJob<T>, hop: SkinHop, then completion: @escaping (T) -> Void,
                            orElse dropped: ((T) -> Void)?) {
        condition.lock()
        running += 1
        condition.unlock()
        job.start { [self] result in
            hop.post({ completion(result) }, orElse: dropped.map { drop in { drop(result) } })
            condition.lock()
            running -= 1
            condition.broadcast()
            condition.unlock()
        }
    }

    func noteService(_ kind: BackgroundWorkKind, config: String, scripted: Bool = false) {
        let request = BackgroundWorkRequest(kind: kind, subject: "", config: config)
        if scripted {
            report(request, faked: true, "the skin's scripted system data")
        } else if case .service? = fake(for: kind)?.source {
            report(request, faked: true, "the host's fake service")
        } else {
            report(request, faked: false, "the service is not faked")
        }
    }

    private func report(_ request: BackgroundWorkRequest, faked: Bool, _ reason: String) {
        let key = "\(request.config)\u{0}\(request.kind.rawValue)\u{0}\(faked)"
        condition.lock()
        if reported.insert(key).inserted {
            reportList.append(BackgroundWorkReport(kind: request.kind, config: request.config, subject: request.subject,
                                                   faked: faked, reason: reason))
        }
        condition.unlock()
    }
}
