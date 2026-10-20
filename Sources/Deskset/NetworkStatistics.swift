import Foundation
import DesksetCore

/// Shared network samples and session-independent byte totals. Adapter names are resolved by SystemMonitor before
/// entering this service. Only the primary app configures a file; other hosts retain an in-memory counter.
final class NetworkStatistics {
    struct Sample {
        var counters: [String: NetworkCounters] = [:]
        var active: [String] = []
        var flags: [String: Int32] = [:]
        var baudRate: [String: UInt64] = [:]
        /// A failed per-interface read may leave a raw fallback value, but it cannot establish a new baseline.
        var unavailable: Set<String> = []
    }

    typealias Sampler = (Sample) -> Sample?
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> SkinScheduledWork

    struct FileIO {
        var read: (URL) throws -> Data?
        var write: (Data, URL) throws -> Void

        static let live = FileIO(read: { url in
            do { return try Data(contentsOf: url) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        }, write: { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        })
    }

    private struct StoredCounter: Codable {
        var received: UInt64
        var sent: UInt64
        init(_ counter: NetworkCounters) { received = counter.received; sent = counter.sent }
        var counter: NetworkCounters { NetworkCounters(received: received, sent: sent) }
    }
    private struct Document: Codable {
        var version: Int
        var interfaces: [String: StoredCounter]
    }
    private enum FileError: Error { case unsupportedVersion }
    private struct TimerID: Equatable {
        var epoch: UInt64
        var serial: UInt64
    }
    private struct State {
        var cache: (sample: Sample, time: TimeInterval)?
        var totals: [String: NetworkCounters] = [:]
        var baselines: [String: NetworkCounters] = [:]
        var active = false
        var dirty = false
        var closed = false
        var fileURL: URL?
        var epoch: UInt64 = 0
        var timerSerial: UInt64 = 0
        var timerID: TimerID?
        var timer: SkinScheduledWork?
        /// Reset during a file read takes precedence over the older totals being loaded.
        var mergeLoadedTotals = true
    }

    static let saveInterval: TimeInterval = 120
    private let state = Guarded(State())
    private let clock: () -> TimeInterval
    private let sample: Sampler
    private let schedule: Schedule
    private let io: FileIO
    private let report: (String) -> Void
    /// All file reads and writes are ordered here. A queued save takes the latest state when it begins, so an old
    /// callback cannot write a snapshot captured before Reset. The final synchronous save is also an exit barrier.
    private let writer = DispatchQueue(label: "com.deskset.network-statistics", qos: .utility)

    init(clock: @escaping () -> TimeInterval,
         sampler: @escaping Sampler,
         schedule: @escaping Schedule = NetworkStatistics.scheduleTimer,
         fileIO: FileIO = .live,
         report: @escaping (String) -> Void = { Log.write($0) }) {
        self.clock = clock
        sample = sampler
        self.schedule = schedule
        io = fileIO
        self.report = report
    }

    deinit { state.current.timer?.cancel() }

    func rawSnapshot() -> Sample {
        state.access { read(&$0, force: false) }
    }

    /// nil selects all physical interfaces; an explicit BSD name also permits virtual interfaces.
    func cumulativeCounters(interface: String?) -> NetworkCounters {
        let result: (NetworkCounters, TimerID?) = state.access { current in
            if !current.closed {
                let first = !current.active
                current.active = true
                current.dirty = true
                _ = read(&current, force: first, baselineOnly: first)
            }
            let value: NetworkCounters
            if let interface { value = current.totals[interface] ?? NetworkCounters() }
            else {
                value = current.totals.reduce(into: NetworkCounters()) { total, pair in
                    if !SystemMonitor.isVirtualInterface(pair.key) { total = Self.add(total, pair.value) }
                }
            }
            return (value, reserveTimer(&current))
        }
        if let timer = result.1 { startTimer(timer) }
        return result.0
    }

    func reset() {
        let epoch: UInt64? = state.access { current in
            guard !current.closed else { return nil }
            current.totals.removeAll()
            current.baselines.removeAll()
            current.mergeLoadedTotals = false
            current.dirty = true
            // Even before activation, capture the reset boundary without starting periodic work. A failed read
            // deliberately leaves the baseline empty; the next successful read establishes it without a delta.
            _ = read(&current, force: true, baselineOnly: true)
            return current.fileURL == nil ? nil : current.epoch
        }
        if let epoch { enqueueSave(epoch: epoch) }
    }

    func configure(fileURL: URL) {
        let previous: (SkinScheduledWork?, UInt64) = state.access { current in
            let timer = current.timer
            current.epoch &+= 1
            current.fileURL = nil
            current.closed = false
            current.active = false
            current.dirty = false
            current.mergeLoadedTotals = true
            current.totals.removeAll()
            current.baselines.removeAll()
            current.timer = nil
            current.timerID = nil
            return (timer, current.epoch)
        }
        previous.0?.cancel()
        let loaded: [String: NetworkCounters] = writer.sync {
            do {
                guard let data = try io.read(fileURL) else { return [:] }
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard document.version == 1 else { throw FileError.unsupportedVersion }
                return document.interfaces.mapValues(\.counter)
            } catch {
                report("Unable to read network statistics at \(fileURL.path): \(error)")
                return [:]
            }
        }
        let start: TimerID? = state.access { current in
            guard current.epoch == previous.1, !current.closed else { return nil }
            // A concurrent cumulative read can already have collected a delta while the file was read.
            if current.mergeLoadedTotals {
                for (name, counter) in loaded {
                    current.totals[name] = Self.add(counter, current.totals[name] ?? NetworkCounters())
                }
            }
            current.fileURL = fileURL
            return reserveTimer(&current)
        }
        if let start { startTimer(start) }
    }

    @discardableResult
    func saveAndStop() -> Bool {
        let stopped: (SkinScheduledWork?, UInt64, Bool) = state.access { current in
            guard !current.closed else { return (nil, current.epoch, false) }
            if current.active { _ = read(&current, force: true) }
            current.closed = true
            current.epoch &+= 1
            let timer = current.timer
            current.timer = nil
            current.timerID = nil
            return (timer, current.epoch, current.fileURL != nil && current.dirty)
        }
        stopped.0?.cancel()
        // Waiting also drains an older write that was already in progress when the epoch changed.
        return writer.sync { stopped.2 ? persist(epoch: stopped.1, final: true) : true }
    }

    private func read(_ current: inout State, force: Bool, baselineOnly: Bool = false) -> Sample {
        if !force, let cached = current.cache, clock() - cached.time < 0.5 { return cached.sample }
        let fallback = current.cache?.sample ?? Sample()
        guard let fresh = sample(fallback) else { return fallback }
        current.cache = (fresh, clock())
        if (current.active && !current.closed) || baselineOnly {
            // An absent interface keeps its accumulated total but needs a new baseline if it returns.
            current.baselines = current.baselines.filter { fresh.counters[$0.key] != nil }
            for (name, counters) in fresh.counters where !fresh.unavailable.contains(name) {
                if !baselineOnly, let before = current.baselines[name] {
                    let delta = NetworkCounters(received: counters.received >= before.received ? counters.received - before.received : 0,
                                                sent: counters.sent >= before.sent ? counters.sent - before.sent : 0)
                    current.totals[name] = Self.add(current.totals[name] ?? NetworkCounters(), delta)
                }
                current.baselines[name] = counters
            }
        }
        return fresh
    }

    private func reserveTimer(_ current: inout State) -> TimerID? {
        guard current.active, !current.closed, current.fileURL != nil, current.timerID == nil else { return nil }
        current.timerSerial &+= 1
        let id = TimerID(epoch: current.epoch, serial: current.timerSerial)
        current.timerID = id
        return id
    }

    private func startTimer(_ id: TimerID) {
        // The injected scheduler may fire inline or return after reconfiguration/exit. Reserve before calling it,
        // then adopt the handle only if the reservation is still current. Neither factory nor cancel runs locked.
        let timer = schedule(Self.saveInterval) { [weak self] in self?.tick(id) }
        let adopted = state.access { current -> Bool in
            guard current.timerID == id, current.epoch == id.epoch, !current.closed else { return false }
            current.timer = timer
            return true
        }
        if !adopted { timer.cancel() }
    }

    private func tick(_ id: TimerID) {
        let valid = state.access { current -> Bool in
            guard current.timerID == id, current.epoch == id.epoch, !current.closed else { return false }
            _ = read(&current, force: true)
            return true
        }
        if valid { enqueueSave(epoch: id.epoch) }
    }

    private func enqueueSave(epoch: UInt64) {
        writer.async { [weak self] in _ = self?.persist(epoch: epoch, final: false) }
    }

    private func persist(epoch: UInt64, final: Bool) -> Bool {
        let snapshot: (URL, Document)? = state.access { current in
            guard current.epoch == epoch, current.closed == final, current.dirty,
                  let url = current.fileURL else { return nil }
            return (url, Document(version: 1, interfaces: current.totals.mapValues(StoredCounter.init)))
        }
        guard let (url, document) = snapshot else { return true }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try io.write(encoder.encode(document), url)
            return true
        } catch {
            report("Unable to save network statistics at \(url.path): \(error)")
            return false
        }
    }

    private static func add(_ first: NetworkCounters, _ second: NetworkCounters) -> NetworkCounters {
        func sum(_ a: UInt64, _ b: UInt64) -> UInt64 {
            let result = a.addingReportingOverflow(b)
            return result.overflow ? .max : result.partialValue
        }
        return NetworkCounters(received: sum(first.received, second.received), sent: sum(first.sent, second.sent))
    }

    static func scheduleTimer(interval: TimeInterval, fire: @escaping () -> Void) -> SkinScheduledWork {
        let work = SkinScheduledWork(repeats: true, fire)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak work] in work?.fire() }
        work.setCancelHandler { timer.cancel() }
        timer.resume()
        return work
    }
}
