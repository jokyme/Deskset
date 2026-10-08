import Darwin
import Foundation

// Per-process and per-core CPU data for AdvancedCPU, UsageMonitor and PerfMon, read with Darwin calls
// (proc_listallpids, proc_pidinfo, proc_pid_rusage, host_processor_info).
//
// What an unprivileged Mac app can see: every process id, but CPU time / memory / disk I/O only for processes that run
// as the same user (root daemons, WindowServer and other system users' processes are closed to it). Their CPU time
// is reported together as the synthetic process "System" (busy time of all cores minus the time of the visible
// processes), and idle time as the synthetic process "Idle", so the per-process CPU values still add up to the whole
// machine like Windows' "Process" counters do.
//
// What a sample costs (Apple silicon, about 600 processes, 400 of them the user's, 2026-09-28, on a performance core;
// the sampler's utility thread may run on an efficiency core, where each call takes about five times as long,
// measured with `taskpolicy -b`): `proc_pid_rusage` version 4 took 0.29 ms for the user's processes and version 2,
// which has every field used here, 0.19 ms; asking for the other users' processes failed one call each, 0.11 ms;
// `proc_taskinfo` took 0.17 ms. So a sample reads version 2, lists only the user's processes, and reads
// `proc_taskinfo` only while a measure needs one of its counters (virtual size, threads, page faults, context
// switches, system calls, priority): 0.63 ms → 0.19 ms.

/// Cumulative counters of one process. Times are in 100-nanosecond units (Windows performance counter units).
struct ProcessRecord: Equatable {
    var pid: Int32
    var name: String
    /// Start time (mach absolute time): tells a reused pid apart.
    var start: UInt64
    var userTime: Double
    var systemTime: Double
    var cpuTime: Double { userTime + systemTime }
    var residentBytes: Double
    var footprintBytes: Double
    var virtualBytes: Double
    var threads: Double
    var pageFaults: Double
    var diskRead: Double
    var diskWrite: Double
    var contextSwitches: Double
    var systemCalls: Double
    var priority: Double
    /// Seconds since the process started.
    var elapsed: Double

    init(pid: Int32, name: String, start: UInt64 = 0, userTime: Double = 0, systemTime: Double = 0,
         residentBytes: Double = 0, footprintBytes: Double = 0, virtualBytes: Double = 0, threads: Double = 0,
         pageFaults: Double = 0, diskRead: Double = 0, diskWrite: Double = 0, contextSwitches: Double = 0,
         systemCalls: Double = 0, priority: Double = 0, elapsed: Double = 0) {
        self.pid = pid
        self.name = name
        self.start = start
        self.userTime = userTime
        self.systemTime = systemTime
        self.residentBytes = residentBytes
        self.footprintBytes = footprintBytes
        self.virtualBytes = virtualBytes
        self.threads = threads
        self.pageFaults = pageFaults
        self.diskRead = diskRead
        self.diskWrite = diskWrite
        self.contextSwitches = contextSwitches
        self.systemCalls = systemCalls
        self.priority = priority
        self.elapsed = elapsed
    }
}

/// Cumulative CPU ticks of one core, in 100-nanosecond units.
struct CoreTicks: Equatable {
    var user: Double
    var system: Double
    var idle: Double
    var nice: Double

    var busy: Double { user + system + nice }
    var total: Double { busy + idle }

    static func + (a: CoreTicks, b: CoreTicks) -> CoreTicks {
        CoreTicks(user: a.user + b.user, system: a.system + b.system, idle: a.idle + b.idle, nice: a.nice + b.nice)
    }

    static let zero = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
}

/// One sample of the whole machine.
struct ProcessSnapshot {
    /// Increases with every sample.
    var serial: Int
    /// Monotonic seconds.
    var time: TimeInterval
    /// Processes whose counters could be read, sorted by pid.
    var processes: [ProcessRecord]
    /// All processes, readable or not.
    var processCount: Int
    var cores: [CoreTicks]
    /// Synthetic cumulative CPU time of the processes that cannot be read (see file comment).
    var hiddenCPU: Double
    /// The processes carry `proc_taskinfo`'s counters (virtual size, threads, page faults, context switches, system
    /// calls, priority): read only while a subscriber needs them (`ProcessSampler.subscribe(_:details:)`).
    var details = true

    var totalTicks: CoreTicks { cores.reduce(.zero, +) }
}

/// A skin's own process samples, read instead of the shared sampler's: the scripted system data of a render or a
/// verification run (`ScriptedSystemData`), as its `system`.
protocol ProcessSampleSource: AnyObject {
    /// The last two samples; nil: the shared sampler's.
    func processSamples() -> (previous: ProcessSnapshot?, latest: ProcessSnapshot?)?
}

/// Reads processes and CPU ticks. Replaceable for tests (`ProcessSampler.provider`).
protocol ProcessDataProvider: AnyObject {
    func readProcesses() -> (visible: [ProcessRecord], total: Int)
    /// Without `details`, the counters only `proc_taskinfo` has (virtual size, threads, context switches, system
    /// calls, priority; page faults are page-ins then) may be left out. `readProcesses()` reads everything.
    func readProcesses(details: Bool) -> (visible: [ProcessRecord], total: Int)
    func readCores() -> [CoreTicks]
}

extension ProcessDataProvider {
    func readProcesses(details: Bool) -> (visible: [ProcessRecord], total: Int) { readProcesses() }
}

/// The Darwin implementation.
final class DarwinProcessData: ProcessDataProvider {
    /// A process: its pid and start time, since pids are reused.
    private struct Key: Hashable {
        let pid: Int32
        let start: UInt64
    }

    private var names: [Key: String] = [:]
    private let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (Double(info.numer == 0 ? 1 : info.numer), Double(info.denom == 0 ? 1 : info.denom))
    }()

    /// Mach time units → 100 ns.
    private func hundredNanoseconds(_ machTime: UInt64) -> Double {
        Double(machTime) * timebase.numer / timebase.denom / 100
    }

    func readProcesses() -> (visible: [ProcessRecord], total: Int) { readProcesses(details: true) }

    func readProcesses(details: Bool) -> (visible: [ProcessRecord], total: Int) {
        // All of them are counted; only the user's can be read (the others' calls would fail, one call each).
        let pids = ProcessNames.allPids()
        let readable = ProcessNames.readablePids() ?? pids
        var records: [ProcessRecord] = []
        records.reserveCapacity(readable.count)
        var seenNames: [Key: String] = [:]
        seenNames.reserveCapacity(readable.count)
        let now = mach_absolute_time()
        for pid in readable where pid > 0 {
            // Version 2 has every field read here (disk I/O came in 2); the later versions add instruction and
            // cycle counts and energy, which made each call half as expensive again.
            var usage = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
                }
            }
            guard ok else { continue }
            var task = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let hasTask = details && proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, size) == size
            let key = Key(pid: pid, start: usage.ri_proc_start_abstime)
            let name = names[key] ?? ProcessNames.name(of: pid) ?? "pid \(pid)"
            seenNames[key] = name
            var record = ProcessRecord(pid: pid, name: name, start: usage.ri_proc_start_abstime)
            record.userTime = hundredNanoseconds(usage.ri_user_time)
            record.systemTime = hundredNanoseconds(usage.ri_system_time)
            record.footprintBytes = Double(usage.ri_phys_footprint)
            record.residentBytes = Double(usage.ri_resident_size)
            record.diskRead = Double(usage.ri_diskio_bytesread)
            record.diskWrite = Double(usage.ri_diskio_byteswritten)
            record.pageFaults = Double(usage.ri_pageins)
            if now > usage.ri_proc_start_abstime {
                record.elapsed = hundredNanoseconds(now - usage.ri_proc_start_abstime) / 10_000_000
            }
            if hasTask {
                record.virtualBytes = Double(task.pti_virtual_size)
                record.threads = Double(task.pti_threadnum)
                record.pageFaults = Double(task.pti_faults)
                record.contextSwitches = Double(task.pti_csw)
                record.systemCalls = Double(task.pti_syscalls_mach) + Double(task.pti_syscalls_unix)
                record.priority = Double(task.pti_priority)
            }
            records.append(record)
        }
        names = seenNames
        records.sort { $0.pid < $1.pid }
        return (records, pids.count)
    }

    func readCores() -> [CoreTicks] { ProcessorTicks.read() }
}

enum ProcessorTicks {
    /// Per-core ticks now (empty when the call fails).
    static func read() -> [CoreTicks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let ticksPerSecond = Double(max(sysconf(Int32(_SC_CLK_TCK)), 1))
        let unit = 10_000_000 / ticksPerSecond
        var cores: [CoreTicks] = []
        let states = Int(CPU_STATE_MAX)
        for i in 0..<Int(count) {
            func tick(_ state: Int32) -> Double { Double(UInt32(bitPattern: info[i * states + Int(state)])) * unit }
            cores.append(CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                                   idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE)))
        }
        return cores
    }
}

/// Process names and ids.
enum ProcessNames {
    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// The processes whose counters this app may read: those of its own (effective) user, the same rule the kernel
    /// applies to `proc_pid_rusage`. Nil for root, which may read every process, and when the list cannot be had.
    static func readablePids() -> [pid_t]? {
        let uid = geteuid()
        guard uid != 0 else { return nil }
        let estimate = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard estimate > 0 else { return nil }
        let stride = MemoryLayout<pid_t>.stride
        var pids = [pid_t](repeating: 0, count: Int(estimate) / stride + 128)
        let bytes = pids.withUnsafeMutableBytes { buffer in
            proc_listpids(UInt32(PROC_UID_ONLY), uid, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return nil }
        return Array(pids.prefix(Int(bytes) / stride))
    }

    /// The executable's file name (`Google Chrome Helper (Renderer)`), else the short process name. A native Swift
    /// string: names are hashed and compared for every process at every sample, which bridged strings made slow.
    static func name(of pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let last = lastPathComponent(String(cString: path))
            if !last.isEmpty { return last }
        }
        var short = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            let s = String(cString: short)
            if !s.isEmpty { return s }
        }
        return nil
    }

    /// Pids whose name matches (case-insensitive; `Rainmeter` means this app).
    static func pids(named raw: String) -> [pid_t] {
        let wanted = normalized(raw)
        let own = normalized(ProcessInfo.processInfo.processName)
        return allPids().filter { pid in
            guard pid > 0, let n = name(of: pid) else { return false }
            let candidate = normalized(n)
            return candidate == wanted || (wanted == "rainmeter" && candidate == own)
        }
    }

    /// What follows the last `/` (trailing slashes ignored), as `NSString.lastPathComponent` gives for an executable's
    /// path, but native.
    static func lastPathComponent(_ path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        guard let slash = trimmed.lastIndex(of: "/"), trimmed.count > 1 else { return String(trimmed) }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// Lowercased, without `.exe`.
    static func normalized(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if n.hasSuffix(".exe") { n = String(n.dropLast(4)) }
        return n
    }
}

/// Samples processes and CPU ticks once a second on a background queue while measures subscribe to it (manual,
/// UsageMonitor: data is gathered "once a second" independently of the skin's Update). One sample of the user's
/// ~400 processes costs about 0.2 ms of a performance core (see the file comment). The first subscriber gets a sample
/// at once; sampling stops when the last one leaves.
///
/// Any thread: skins on different threads subscribe and leave at the same time, so whether to start or stop the timer
/// is decided and carried out under one lock (docs/skin-threading.md §4.10). Deciding under the lock and acting after
/// it let a skin that joined just as the last other one left end up subscribed to a stopped timer. A sample taken by a
/// timer that was stopped meanwhile is dropped.
final class ProcessSampler: @unchecked Sendable {
    static let shared = ProcessSampler()

    /// Data provider; tests swap in fakes (set before subscribing).
    static var provider: ProcessDataProvider = DarwinProcessData()
    /// Sampling period in seconds.
    static var interval: TimeInterval = 1

    private let queue = DispatchQueue(label: "Deskset.ProcessSampler", qos: .utility)
    private let lock = NSLock()
    /// Each subscriber, and whether it reads `proc_taskinfo`'s counters (`ProcessSnapshot.details`).
    private var subscribers: [ObjectIdentifier: Bool] = [:]
    private var timer: DispatchSourceTimer?
    /// Counts the timers started: a sample of an older one is not kept.
    private var timerGeneration = 0
    private var snapshots: (previous: ProcessSnapshot?, latest: ProcessSnapshot?) = (nil, nil)
    private var serial = 0
    private var hiddenCPU = 0.0

    /// Starts sampling for `owner` (idempotent; a later call changes what it needs). `details`: it reads counters
    /// only `proc_taskinfo` has (`PerfCounterSpec.needsDetails`); while no subscriber does, samples leave them out.
    func subscribe(_ owner: AnyObject, details: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        let inserted = subscribers.updateValue(details, forKey: ObjectIdentifier(owner)) == nil
        if inserted && subscribers.count == 1 { startTimer() }
    }

    func unsubscribe(_ owner: AnyObject) {
        unsubscribe(id: ObjectIdentifier(owner))
    }

    /// For `deinit`, where `self` can no longer be passed around.
    func unsubscribe(id: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        let removed = subscribers.removeValue(forKey: id) != nil
        if removed && subscribers.isEmpty { stopTimer() }
    }

    /// The last two samples (previous may be nil right after sampling started). With `details`, only samples that
    /// carry `proc_taskinfo`'s counters: one taken before the first subscriber that needs them joined has none, and
    /// counts as not taken.
    func samples(details: Bool = false) -> (previous: ProcessSnapshot?, latest: ProcessSnapshot?) {
        lock.lock(); defer { lock.unlock() }
        guard details else { return snapshots }
        guard snapshots.latest?.details != false else { return (nil, nil) }
        return (snapshots.previous?.details == false ? nil : snapshots.previous, snapshots.latest)
    }

    /// Whether the next sample reads `proc_taskinfo` (tests).
    var readsDetails: Bool {
        lock.lock(); defer { lock.unlock() }
        return subscribers.values.contains(true)
    }

    /// The samples measures read: their system's own (`ProcessSampleSource`), else the shared sampler's
    /// (`details` as in `samples(details:)`).
    static func samples(for system: SystemDataSource,
                        details: Bool = false) -> (previous: ProcessSnapshot?, latest: ProcessSnapshot?) {
        readSamples(for: system, details: details).samples
    }

    /// `samples(for:details:)`, and whether they are the shared sampler's (`shared`): only those have the serials
    /// that results shared between the measures of every skin are keyed by (a skin's own samples count their own).
    static func readSamples(for system: SystemDataSource, details: Bool = false)
        -> (samples: (previous: ProcessSnapshot?, latest: ProcessSnapshot?), shared: Bool) {
        if let own = (system as? ProcessSampleSource)?.processSamples() { return (own, false) }
        return (shared.samples(details: details), true)
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return timer != nil
    }

    /// With `lock` held. Creating, resuming and cancelling a timer never wait for its handler (a sample in progress
    /// finishes on the queue and is then dropped, see `sample`).
    private func startTimer() {
        timer?.cancel()
        timerGeneration += 1
        let generation = timerGeneration
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: ProcessSampler.interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.sample(generation: generation) }
        timer = t
        t.resume()
    }

    /// With `lock` held.
    private func stopTimer() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
        snapshots = (nil, nil)
        hiddenCPU = 0
    }

    /// Takes a sample now (on the sampler queue) for the timer of `generation` (nil: whichever runs). Tests call
    /// `sampleNow()` to step deterministically.
    private func sample(generation: Int? = nil) {
        let provider = ProcessSampler.provider
        let details = readsDetails
        let cores = provider.readCores()
        // The time of the core ticks: rates divide their change by the change of this time, and the process walk
        // below can take a while (cold name cache, or this utility thread waiting for a core on a busy Mac).
        let now = ProcessInfo.processInfo.systemUptime
        let (visible, total) = provider.readProcesses(details: details)
        lock.lock()
        // Stopped (and perhaps started again) while this sample was taken: it belongs to no subscription.
        if let generation, generation != timerGeneration {
            lock.unlock()
            return
        }
        let previous = snapshots.latest
        serial += 1
        if let previous {
            // CPU the visible processes cannot account for in this interval → the synthetic "System" process.
            let busyDelta = max(0, cores.reduce(CoreTicks.zero, +).busy - previous.totalTicks.busy)
            let visibleDelta = ProcessSampler.cpuDelta(from: previous.processes, to: visible)
            hiddenCPU += max(0, busyDelta - visibleDelta)
        }
        let snapshot = ProcessSnapshot(serial: serial, time: now, processes: visible, processCount: total,
                                       cores: cores, hiddenCPU: hiddenCPU, details: details)
        snapshots = (previous, snapshot)
        lock.unlock()
    }

    /// Synchronous sample for tests.
    func sampleNow() {
        queue.sync { sample() }
    }

    /// CPU time used between two process lists (pids matched with their start time; a new process counts from 0).
    static func cpuDelta(from old: [ProcessRecord], to new: [ProcessRecord]) -> Double {
        var before: [Int32: ProcessRecord] = [:]
        for p in old { before[p.pid] = p }
        var sum = 0.0
        for p in new {
            if let o = before[p.pid], o.start == p.start {
                sum += max(0, p.cpuTime - o.cpuTime)
            } else {
                sum += p.cpuTime
            }
        }
        return sum
    }
}

// MARK: - Per-process CPU deltas (AdvancedCPU, Process counters)

/// CPU time of each process between two samples, including the synthetic `Idle` and `System` processes.
struct ProcessCPUInterval {
    struct Entry {
        var name: String
        var pid: Int32
        /// 100-ns units used during the interval.
        var cpu: Double
    }

    var entries: [Entry]
    /// Seconds between the samples.
    var seconds: Double
    var coreCount: Int

    init(from old: ProcessSnapshot, to new: ProcessSnapshot) {
        var before: [Int32: ProcessRecord] = [:]
        for p in old.processes { before[p.pid] = p }
        var list: [Entry] = []
        list.reserveCapacity(new.processes.count + 2)
        for p in new.processes {
            let delta: Double
            if let o = before[p.pid], o.start == p.start {
                delta = max(0, p.cpuTime - o.cpuTime)
            } else {
                delta = p.cpuTime
            }
            list.append(Entry(name: p.name, pid: p.pid, cpu: delta))
        }
        let idle = max(0, new.totalTicks.idle - old.totalTicks.idle)
        list.append(Entry(name: "Idle", pid: 0, cpu: idle))
        list.append(Entry(name: "System", pid: -1, cpu: max(0, new.hiddenCPU - old.hiddenCPU)))
        entries = list
        seconds = max(new.time - old.time, 0)
        coreCount = max(new.cores.count, 1)
    }
}
