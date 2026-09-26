import Darwin
import Foundation

// Windows Performance Monitor counters (as used by UsageMonitor and the deprecated PerfMon plugin) mapped onto Mac
// data. Only the category / counter / instance *names* and their documented meaning come from the manual
// (/manual/plugins/usagemonitor/, /manual/plugins/deprecated/perfmon/); how each maps onto macOS is our choice and is
// listed in docs/compat/plugins.md. Names are matched case-insensitively (Windows: case-sensitive).
//
// Every counter has a "raw" value (what Performance Monitor stores: a cumulative count, a cumulative time in 100 ns
// units, or an instantaneous value) and a "formatted" value (what the Perfmon GUI shows: per second, percent, …):
// - instant:      formatted = raw
// - rate:         raw is cumulative; formatted = Δraw / Δseconds
// - timer:        raw is cumulative 100 ns; formatted = Δraw / Δtime × 100 (percent of one core)
// - inverseTimer: raw is cumulative *idle* 100 ns (Processor "% Processor Time"); formatted = 100 − idle percent
// - fraction:     formatted = raw / base × 100

enum PerfCategory: String, CaseIterable {
    case processor = "processor"
    case processorInformation = "processor information"
    case process = "process"
    case memory = "memory"
    case pagingFile = "paging file"
    case networkInterface = "network interface"
    case networkAdapter = "network adapter"
    case logicalDisk = "logicaldisk"
    case physicalDisk = "physicaldisk"
    case system = "system"
    case thermalZone = "thermal zone information"
    case gpuEngine = "gpu engine"
    case gpuProcessMemory = "gpu process memory"
    case gpuAdapterMemory = "gpu adapter memory"

    /// True when the category has one value and no instances.
    var isSingleInstance: Bool { self == .memory || self == .system }
}

enum PerfKind {
    case instant, rate, timer, inverseTimer, fraction
}

/// What a counter reads.
enum PerfField: Equatable {
    // Processor (per core)
    case coreIdle, coreUser, coreSystem, coreBusyPercent, coreFrequency, constant(Double)
    // Process (per process)
    case processCPU, processUser, processSystem, processFootprint, processResident, processVirtual, processThreads
    case processPid, processElapsed, processPriority, processFaults, processRead, processWrite, processIO
    // Machine-wide
    case memoryAvailable(divisor: Double), memoryCommitted, memoryCommitLimit, memoryCommittedPercent
    case swapPercent, pageFaults
    case netIn, netOut, netTotal
    case diskFreePercent, diskFreeMegabytes, diskRead, diskWrite, diskIO
    case processCount, threadCount, uptime, loadAverage, contextSwitches, systemCalls
    case temperatureKelvin(scale: Double), gpuUtilization
    /// Known counter without a Mac equivalent: no instances.
    case unavailable
}

struct PerfCounterSpec: Equatable {
    var category: PerfCategory
    var counter: String
    var kind: PerfKind
    var field: PerfField

    /// Needs the background process sampler.
    var needsProcesses: Bool {
        switch field {
        case .processCPU, .processUser, .processSystem, .processFootprint, .processResident, .processVirtual,
             .processThreads, .processPid, .processElapsed, .processPriority, .processFaults, .processRead,
             .processWrite, .processIO, .pageFaults, .diskRead, .diskWrite, .diskIO, .contextSwitches, .systemCalls,
             .processCount:
            return true
        default:
            return false
        }
    }

    var isProcessField: Bool { category == .process }
    /// Reads per-core CPU ticks (every Processor / Processor Information counter).
    var usesCores: Bool { category == .processor || category == .processorInformation }
}

/// One instance of a counter.
struct PerfValue: Equatable {
    var name: String
    var value: Double
}

enum PerfCounters {
    /// The counter for `category` / `counter` (case-insensitive), or nil when unknown.
    static func spec(category rawCategory: String, counter rawCounter: String) -> PerfCounterSpec? {
        let c = rawCategory.trimmingCharacters(in: .whitespaces).lowercased()
        let n = rawCounter.trimmingCharacters(in: .whitespaces).lowercased()
        guard let category = PerfCategory(rawValue: c) else { return nil }
        func make(_ kind: PerfKind, _ field: PerfField) -> PerfCounterSpec {
            PerfCounterSpec(category: category, counter: n, kind: kind, field: field)
        }
        switch category {
        case .processor, .processorInformation:
            switch n {
            case "% processor time", "% processor utility": return make(.inverseTimer, .coreIdle)
            case "% idle time", "% c1 time": return make(.timer, .coreIdle)
            case "% user time": return make(.timer, .coreUser)
            case "% privileged time": return make(.timer, .coreSystem)
            case "% interrupt time", "% dpc time", "% c2 time", "% c3 time", "interrupts/sec", "dpcs queued/sec",
                 "dpc rate", "c1 transitions/sec", "c2 transitions/sec", "c3 transitions/sec", "% priority time":
                return make(.instant, .constant(0))
            case "% processor performance", "% of maximum frequency", "% performance limit":
                return make(.instant, .constant(100))
            case "processor frequency": return make(.instant, .coreFrequency)
            default: return nil
            }
        case .process:
            switch n {
            case "% processor time": return make(.timer, .processCPU)
            case "% user time": return make(.timer, .processUser)
            case "% privileged time": return make(.timer, .processSystem)
            case "working set - private", "private bytes", "page file bytes", "page file bytes peak":
                return make(.instant, .processFootprint)
            case "working set", "working set peak": return make(.instant, .processResident)
            case "virtual bytes", "virtual bytes peak": return make(.instant, .processVirtual)
            case "thread count": return make(.instant, .processThreads)
            case "id process": return make(.instant, .processPid)
            case "elapsed time": return make(.instant, .processElapsed)
            case "priority base": return make(.instant, .processPriority)
            case "page faults/sec": return make(.rate, .processFaults)
            case "io read bytes/sec": return make(.rate, .processRead)
            case "io write bytes/sec": return make(.rate, .processWrite)
            case "io data bytes/sec": return make(.rate, .processIO)
            case "handle count", "pool paged bytes", "pool nonpaged bytes", "io other bytes/sec",
                 "io read operations/sec", "io write operations/sec", "io data operations/sec",
                 "io other operations/sec", "creating process id":
                return make(.instant, .constant(0))
            default: return nil
            }
        case .memory:
            switch n {
            case "available bytes", "free & zero page list bytes": return make(.instant, .memoryAvailable(divisor: 1))
            case "available kbytes": return make(.instant, .memoryAvailable(divisor: 1024))
            case "available mbytes": return make(.instant, .memoryAvailable(divisor: 1_048_576))
            case "committed bytes": return make(.instant, .memoryCommitted)
            case "commit limit": return make(.instant, .memoryCommitLimit)
            case "% committed bytes in use": return make(.fraction, .memoryCommittedPercent)
            case "page faults/sec": return make(.rate, .pageFaults)
            case "cache bytes", "cache bytes peak", "pool paged bytes", "pool nonpaged bytes", "pages/sec",
                 "page reads/sec", "page writes/sec", "pages input/sec", "pages output/sec", "cache faults/sec",
                 "modified page list bytes", "standby cache normal priority bytes", "standby cache reserve bytes",
                 "standby cache core bytes", "transition faults/sec", "demand zero faults/sec",
                 "system cache resident bytes", "free system page table entries":
                return make(.instant, .constant(0))
            default: return nil
            }
        case .pagingFile:
            switch n {
            case "% usage", "% usage peak": return make(.fraction, .swapPercent)
            default: return nil
            }
        case .networkInterface, .networkAdapter:
            switch n {
            case "bytes received/sec": return make(.rate, .netIn)
            case "bytes sent/sec": return make(.rate, .netOut)
            case "bytes total/sec": return make(.rate, .netTotal)
            case "current bandwidth", "packets/sec", "packets received/sec", "packets sent/sec",
                 "packets received errors", "packets outbound errors", "packets received discarded",
                 "packets outbound discarded", "output queue length":
                return make(.instant, .constant(0))
            default: return nil
            }
        case .logicalDisk, .physicalDisk:
            switch n {
            case "% free space": return category == .logicalDisk ? make(.fraction, .diskFreePercent) : nil
            case "free megabytes": return category == .logicalDisk ? make(.instant, .diskFreeMegabytes) : nil
            case "disk read bytes/sec": return make(.rate, .diskRead)
            case "disk write bytes/sec": return make(.rate, .diskWrite)
            case "disk bytes/sec": return make(.rate, .diskIO)
            case "% disk time", "% disk read time", "% disk write time", "% idle time", "current disk queue length",
                 "avg. disk queue length", "avg. disk read queue length", "avg. disk write queue length",
                 "disk transfers/sec", "disk reads/sec", "disk writes/sec", "avg. disk sec/read",
                 "avg. disk sec/write", "avg. disk sec/transfer", "avg. disk bytes/read", "avg. disk bytes/write",
                 "avg. disk bytes/transfer", "split io/sec":
                return make(.instant, .constant(0))
            default: return nil
            }
        case .system:
            switch n {
            case "processes": return make(.instant, .processCount)
            case "threads": return make(.instant, .threadCount)
            case "system up time": return make(.instant, .uptime)
            case "processor queue length": return make(.instant, .loadAverage)
            case "context switches/sec": return make(.rate, .contextSwitches)
            case "system calls/sec": return make(.rate, .systemCalls)
            case "file read bytes/sec": return make(.rate, .diskRead)
            case "file write bytes/sec": return make(.rate, .diskWrite)
            case "file data operations/sec", "file read operations/sec", "file write operations/sec",
                 "exception dispatches/sec", "alignment fixups/sec", "floating emulations/sec", "% registry quota in use":
                return make(.instant, .constant(0))
            default: return nil
            }
        case .thermalZone:
            switch n {
            case "temperature": return make(.instant, .temperatureKelvin(scale: 1))
            case "high precision temperature": return make(.instant, .temperatureKelvin(scale: 10))
            case "% passive limit": return make(.instant, .constant(100))
            case "throttle reasons": return make(.instant, .constant(0))
            default: return nil
            }
        case .gpuEngine:
            switch n {
            case "utilization percentage", "running time": return make(.instant, .gpuUtilization)
            default: return nil
            }
        case .gpuProcessMemory, .gpuAdapterMemory:
            switch n {
            case "dedicated usage", "shared usage", "total committed", "local usage", "non local usage":
                return make(.instant, .unavailable)
            default: return nil
            }
        }
    }

    // MARK: Reading

    /// Machine-wide inputs for one reading.
    struct Context {
        var system: SystemDataSource
        var sensors: HardwareSensorSource?
        /// Process sample (needed by `needsProcesses` counters).
        var snapshot: ProcessSnapshot?
        /// Core ticks (Processor counters).
        var cores: [CoreTicks]
        /// Monotonic seconds.
        var time: TimeInterval
    }

    /// Cumulative / instantaneous raw values per instance, with a base for fractions. Process counters are read per
    /// process (see `processValues`); this handles every other category.
    struct RawReading {
        var time: TimeInterval
        var instances: [(name: String, raw: Double, base: Double)]
    }

    static func rawReading(_ spec: PerfCounterSpec, _ ctx: Context) -> RawReading {
        var list: [(String, Double, Double)] = []
        func single(_ name: String, _ raw: Double, _ base: Double = 0) { list.append((name, raw, base)) }
        let snapshot = ctx.snapshot
        switch spec.field {
        case .coreIdle, .coreUser, .coreSystem, .coreBusyPercent, .coreFrequency, .constant:
            if spec.category == .processor || spec.category == .processorInformation {
                let cores = ctx.cores
                let info = spec.category == .processorInformation
                var sum = CoreTicks.zero
                for (i, c) in cores.enumerated() {
                    sum = sum + c
                    single(info ? "0,\(i)" : "\(i)", coreValue(spec.field, c, ctx))
                }
                let n = Double(max(cores.count, 1))
                let average = CoreTicks(user: sum.user / n, system: sum.system / n, idle: sum.idle / n,
                                        nice: sum.nice / n)
                single("_Total", coreValue(spec.field, average, ctx))
                if info { single("0,_Total", coreValue(spec.field, average, ctx)) }
            } else if case .constant(let v) = spec.field {
                for name in defaultInstances(spec.category, ctx) { single(name, v) }
            }
        case .memoryAvailable(let divisor):
            let m = ctx.system.memoryStatus()
            single("", max(0, m.physicalTotal - m.physicalUsed) / divisor)
        case .memoryCommitted:
            let m = ctx.system.memoryStatus()
            single("", m.physicalUsed + m.swapUsed)
        case .memoryCommitLimit:
            let m = ctx.system.memoryStatus()
            single("", m.physicalTotal + m.swapTotal)
        case .memoryCommittedPercent:
            let m = ctx.system.memoryStatus()
            single("", m.physicalUsed + m.swapUsed, m.physicalTotal + m.swapTotal)
        case .swapPercent:
            let m = ctx.system.memoryStatus()
            single("_Total", m.swapUsed, m.swapTotal)
        case .pageFaults:
            single("", snapshot?.processes.reduce(0) { $0 + $1.pageFaults } ?? 0)
        case .netIn, .netOut, .netTotal:
            func pick(_ c: NetworkCounters) -> Double {
                switch spec.field {
                case .netIn: return Double(c.received)
                case .netOut: return Double(c.sent)
                default: return Double(c.received) + Double(c.sent)
                }
            }
            for interface in ctx.system.networkInterfaces() {
                single(interface, pick(ctx.system.networkCounters(interface: interface)))
            }
        case .diskFreePercent, .diskFreeMegabytes:
            let space = ctx.system.diskSpace(path: "/")
            let free = space?.free ?? 0, total = space?.total ?? 0
            for name in ["C:", "_Total"] {
                if spec.field == .diskFreePercent { single(name, free, total) } else { single(name, free / 1_048_576) }
            }
        case .diskRead, .diskWrite, .diskIO:
            let processes = snapshot?.processes ?? []
            let raw: Double
            switch spec.field {
            case .diskRead: raw = processes.reduce(0) { $0 + $1.diskRead }
            case .diskWrite: raw = processes.reduce(0) { $0 + $1.diskWrite }
            default: raw = processes.reduce(0) { $0 + $1.diskRead + $1.diskWrite }
            }
            if spec.category == .system {
                single("", raw)
            } else {
                for name in defaultInstances(spec.category, ctx) { single(name, raw) }
            }
        case .processCount:
            single("", Double(snapshot?.processCount ?? ProcessNames.allPids().count))
        case .threadCount:
            single("", Double(sysctlInt("kern.num_threads") ?? 0))
        case .uptime:
            single("", ctx.system.uptime())
        case .loadAverage:
            var loads = [Double](repeating: 0, count: 3)
            single("", getloadavg(&loads, 3) > 0 ? loads[0] : 0)
        case .contextSwitches:
            single("", snapshot?.processes.reduce(0) { $0 + $1.contextSwitches } ?? 0)
        case .systemCalls:
            single("", snapshot?.processes.reduce(0) { $0 + $1.systemCalls } ?? 0)
        case .temperatureKelvin(let scale):
            if let t = ctx.sensors?.cpuPackageTemperature() {
                single("\\_TZ.CPU", ((t + 273.15) * scale).rounded())
            }
        case .gpuUtilization:
            if let u = ctx.sensors?.gpuUtilization() { single("GPU", u) }
        case .unavailable:
            break
        case .processCPU, .processUser, .processSystem, .processFootprint, .processResident, .processVirtual,
             .processThreads, .processPid, .processElapsed, .processPriority, .processFaults, .processRead,
             .processWrite, .processIO:
            break
        }
        return RawReading(time: ctx.time, instances: list.map { (name: $0.0, raw: $0.1, base: $0.2) })
    }

    private static func coreValue(_ field: PerfField, _ c: CoreTicks, _ ctx: Context) -> Double {
        switch field {
        case .coreIdle: return c.idle
        case .coreUser: return c.user + c.nice
        case .coreSystem: return c.system
        case .coreBusyPercent: return c.total > 0 ? c.busy / c.total * 100 : 0
        case .coreFrequency:
            if let list = ctx.sensors?.cpuCoreFrequencies(), let max = list.max() { return max }
            return (ctx.system.cpuFrequency() ?? 0) / 1_000_000
        case .constant(let v): return v
        default: return 0
        }
    }

    /// Instance names of categories whose values are machine-wide.
    private static func defaultInstances(_ category: PerfCategory, _ ctx: Context) -> [String] {
        switch category {
        case .logicalDisk: return ["C:", "_Total"]
        case .physicalDisk: return ["0 C:", "_Total"]
        case .processor: return (0..<max(ctx.cores.count, 1)).map { "\($0)" } + ["_Total"]
        case .processorInformation: return (0..<max(ctx.cores.count, 1)).map { "0,\($0)" } + ["_Total", "0,_Total"]
        case .networkInterface, .networkAdapter: return ctx.system.networkInterfaces()
        case .pagingFile: return ["_Total"]
        case .process: return ["_Total"]
        default: return [""]
        }
    }

    /// How a value is reported.
    enum Mode {
        /// The Perfmon GUI value (per second, percent…).
        case formatted
        /// The stored counter value.
        case raw
        /// Difference of the stored counter value between two readings (PerfMon `PerfMonDifference=1`).
        case rawDelta
    }

    /// Values of a non-process counter from two raw readings (`old` nil: first reading).
    static func values(_ spec: PerfCounterSpec, old: RawReading?, new: RawReading, mode: Mode) -> [PerfValue] {
        var before: [String: Double] = [:]
        for i in old?.instances ?? [] { before[i.name] = i.raw }
        let seconds = old.map { new.time - $0.time } ?? 0
        return new.instances.map { instance in
            let previous = before[instance.name]
            let v: Double
            switch mode {
            case .raw:
                v = instance.raw
            case .rawDelta:
                v = previous.map { instance.raw - $0 } ?? 0
            case .formatted:
                switch spec.kind {
                case .instant:
                    v = instance.raw
                case .fraction:
                    v = instance.base > 0 ? instance.raw / instance.base * 100 : 0
                case .rate:
                    guard let previous, seconds > 0 else { v = 0; break }
                    v = max(0, instance.raw - previous) / seconds
                case .timer, .inverseTimer:
                    guard let previous, seconds > 0 else { v = spec.kind == .inverseTimer ? 0 : 0; break }
                    let percent = min(max((instance.raw - previous) / (seconds * 10_000_000) * 100, 0), 100)
                    v = spec.kind == .inverseTimer ? 100 - percent : percent
                }
            }
            return PerfValue(name: instance.name, value: v.isFinite ? v : 0)
        }
    }

    // MARK: Process counters

    /// Per-process values between two samples, with the synthetic `Idle`, `System` and `_Total` instances.
    /// `rollup`: processes with the same name are added up under that name; otherwise duplicates are named
    /// `name`, `name#1`, `name#2`… in pid order (Windows' convention).
    static func processValues(_ spec: PerfCounterSpec, old: ProcessSnapshot?, new: ProcessSnapshot, mode: Mode,
                              rollup: Bool) -> [PerfValue] {
        var before: [Int32: ProcessRecord] = [:]
        for p in old?.processes ?? [] { before[p.pid] = p }
        let seconds = old.map { new.time - $0.time } ?? 0

        func raw(_ p: ProcessRecord) -> Double {
            switch spec.field {
            case .processCPU: return p.cpuTime
            case .processUser: return p.userTime
            case .processSystem: return p.systemTime
            case .processFootprint: return p.footprintBytes
            case .processResident: return p.residentBytes
            case .processVirtual: return p.virtualBytes
            case .processThreads: return p.threads
            case .processPid: return Double(p.pid)
            case .processElapsed: return p.elapsed
            case .processPriority: return p.priority
            case .processFaults: return p.pageFaults
            case .processRead: return p.diskRead
            case .processWrite: return p.diskWrite
            case .processIO: return p.diskRead + p.diskWrite
            case .constant(let v): return v
            default: return 0
            }
        }

        func value(current: Double, previous: Double?) -> Double {
            switch mode {
            case .raw: return current
            case .rawDelta: return previous.map { max(0, current - $0) } ?? 0
            case .formatted:
                switch spec.kind {
                case .instant, .fraction: return current
                case .rate:
                    guard let previous, seconds > 0 else { return 0 }
                    return max(0, current - previous) / seconds
                case .timer, .inverseTimer:
                    guard let previous, seconds > 0 else { return 0 }
                    return max(0, current - previous) / (seconds * 10_000_000) * 100
                }
            }
        }

        var entries: [(name: String, value: Double)] = []
        entries.reserveCapacity(new.processes.count + 3)
        for p in new.processes {
            var previous: Double?
            if let o = before[p.pid] {
                previous = o.start == p.start ? raw(o) : 0
            } else if old != nil {
                previous = 0   // started during the interval: all of its counters are new
            }
            entries.append((p.name, value(current: raw(p), previous: previous)))
        }
        // Synthetic processes: CPU only.
        let cpuField = spec.field == .processCPU || spec.field == .processSystem
        let oldIdle = old?.totalTicks.idle, oldHidden = old?.hiddenCPU
        entries.append(("Idle", cpuField ? value(current: new.totalTicks.idle, previous: oldIdle) : 0))
        entries.append(("System", cpuField ? value(current: new.hiddenCPU, previous: oldHidden) : 0))

        var result: [PerfValue] = []
        if rollup {
            var index: [String: Int] = [:]
            for e in entries {
                if let i = index[e.name] {
                    result[i].value += e.value
                } else {
                    index[e.name] = result.count
                    result.append(PerfValue(name: e.name, value: e.value))
                }
            }
        } else {
            var seen: [String: Int] = [:]
            for e in entries {
                let n = seen[e.name, default: 0]
                seen[e.name] = n + 1
                result.append(PerfValue(name: n == 0 ? e.name : "\(e.name)#\(n)", value: e.value))
            }
        }
        let total = result.reduce(0) { $0 + $1.value }
        result.append(PerfValue(name: "_Total", value: total))
        return result
    }

    /// `name` in `values`: exact, then case-insensitive, then without `.exe`; `Rainmeter` is this app's process;
    /// a Processor Information core may be written `N` for `0,N`.
    static func find(_ name: String, in values: [PerfValue], category: PerfCategory) -> PerfValue? {
        if let v = values.first(where: { $0.name == name }) { return v }
        let wanted = ProcessNames.normalized(name)
        if let v = values.first(where: { ProcessNames.normalized($0.name) == wanted }) { return v }
        if category == .process, wanted == "rainmeter" {
            let own = ProcessNames.normalized(ProcessInfo.processInfo.processName)
            if let v = values.first(where: { ProcessNames.normalized($0.name) == own }) { return v }
        }
        if category == .processorInformation, let v = values.first(where: { $0.name == "0," + name }) { return v }
        return nil
    }
}
