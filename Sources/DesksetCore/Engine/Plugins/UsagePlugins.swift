import Foundation

// Clean-room implementations from the public manual only:
//   https://docs.rainmeter.net/manual/plugins/usagemonitor/
//   https://docs.rainmeter.net/manual/plugins/deprecated/perfmon/
//   https://docs.rainmeter.net/manual/plugins/deprecated/advancedcpu/
// The Windows counters are emulated by PerfCounters / ProcessSampler (see those files).

// MARK: - UsageMonitor

/// `Plugin=UsageMonitor`.
/// - `Alias` (CPU, RAM, RAMSHARED, IO, IOREAD, IOWRITE, GPU, VRAM, VRAMSHARED) or `Category` + `Counter`.
/// - `Index=0` (default): sum of all instances, string "Total"; `Index=-1`: average, "Average"; `Index=N`: the Nth
///   highest instance and its name ("" when its value is 0); `Name=`: that instance (overrides Index).
/// - `Blacklist` (default `_Total|Idle`) / `Whitelist` (overrides it), `|`-separated; `Rollup=1` (default) adds up
///   same-named processes; `Percent=1` divides by the `_Total` instance (automatic with Alias=CPU); `RawValue=1`
///   returns the stored counter value; `PIDToName=1` shows the process name for "ID Process" values.
/// - Values come from a sample taken once a second (independent of Update), as the manual describes.
/// Mac differences (docs/compat/plugins.md): process names are Mac executable names; other users' processes are
/// summed up as "System"; GPU needs a sensor source; names are matched case-insensitively.
public final class UsageMonitorMeasure: Measure, PluginLifecycle {
    private var spec: PerfCounterSpec?
    private var index = 0
    private var instanceName: String?
    private var blacklist: [String] = []
    private var whitelist: [String]?
    private var rollup = true
    private var percent = false
    private var rawValue = false
    private var pidToName = false
    private var subscribed = false
    private var lastSystemReading: PerfCounters.RawReading?
    private var cachedSerial: Int?
    private var cachedResult: (Double, String) = (0, "")
    private var reported: Set<String> = []

    override var tracksValueRange: Bool { true }

    deinit {
        if subscribed { ProcessSampler.shared.unsubscribe(id: ObjectIdentifier(self)) }
    }

    public func skinWillClose() {
        if subscribed {
            subscribed = false
            ProcessSampler.shared.unsubscribe(self)
        }
    }

    public override func readMeasureOptions() {
        let category = string("Category").trimmingCharacters(in: .whitespaces)
        let counter = string("Counter").trimmingCharacters(in: .whitespaces)
        let alias = string("Alias").trimmingCharacters(in: .whitespaces).uppercased()
        var autoPercent = false
        var autoPIDToName = false
        var newSpec: PerfCounterSpec?
        if !category.isEmpty || !counter.isEmpty {
            newSpec = PerfCounters.spec(category: category, counter: counter)
            if newSpec == nil {
                report("counter", "UsageMonitor [\(name)]: counter \"\(category)\\\(counter)\" is not available on macOS; the value is 0")
                skin.addIssue("UsageMonitor counter \(category)\\\(counter) is not available on macOS")
            }
        } else if !alias.isEmpty {
            let pair: (String, String)?
            switch alias {
            case "CPU": pair = ("Process", "% Processor Time"); autoPercent = true
            case "RAM": pair = ("Process", "Working Set - Private")
            case "RAMSHARED": pair = ("Process", "Working Set")
            case "IO": pair = ("Process", "IO Data Bytes/sec")
            case "IOREAD": pair = ("Process", "IO Read Bytes/sec")
            case "IOWRITE": pair = ("Process", "IO Write Bytes/sec")
            case "GPU": pair = ("GPU Engine", "Utilization Percentage"); autoPIDToName = true
            case "VRAM": pair = ("GPU Process Memory", "Dedicated Usage"); autoPIDToName = true
            case "VRAMSHARED": pair = ("GPU Process Memory", "Shared Usage"); autoPIDToName = true
            default:
                pair = nil
                report("alias", "UsageMonitor [\(name)]: unknown Alias=\(alias); the value is 0")
            }
            newSpec = pair.flatMap { PerfCounters.spec(category: $0.0, counter: $0.1) }
        } else {
            report("none", "UsageMonitor [\(name)]: no Alias or Category/Counter; the value is 0")
        }
        if let s = newSpec, s.field == .gpuUtilization || s.field == .unavailable,
           HardwareSensors.source(for: skin)?.gpuUtilization() == nil {
            report("gpu", "UsageMonitor [\(name)]: GPU usage per process is not available on macOS; the value is 0")
        }
        if newSpec != spec {
            spec = newSpec
            lastSystemReading = nil
            cachedSerial = nil
        }
        index = min(max(int("Index", 0), -1), 100_000)
        let n = string("Name")
        instanceName = n.isEmpty ? nil : n
        let white = string("Whitelist")
        whitelist = white.isEmpty ? nil : UsageMonitorMeasure.names(white)
        blacklist = UsageMonitorMeasure.names(option("Blacklist") ?? "_Total|Idle")
        rollup = bool("Rollup", true)
        percent = bool("Percent", autoPercent)
        rawValue = bool("RawValue", false)
        pidToName = bool("PIDToName", autoPIDToName)
        cachedSerial = nil
        let needsSampler = spec?.needsProcesses == true || spec?.usesCores == true
        if needsSampler && !subscribed {
            subscribed = true
            ProcessSampler.shared.subscribe(self)
        } else if !needsSampler && subscribed {
            subscribed = false
            ProcessSampler.shared.unsubscribe(self)
        }
    }

    static func names(_ list: String) -> [String] {
        list.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public override func computeValue() -> Double {
        guard let spec else {
            rawString = ""
            return 0
        }
        let values: [PerfValue]
        if spec.needsProcesses || spec.usesCores {
            let samples = ProcessSampler.shared.samples()
            guard let latest = samples.latest else {
                rawString = cachedResult.1
                return cachedResult.0
            }
            if cachedSerial == latest.serial {
                rawString = cachedResult.1
                return cachedResult.0
            }
            cachedSerial = latest.serial
            values = UsageMonitorMeasure.values(spec, previous: samples.previous, latest: latest,
                                                context: context(snapshot: latest, cores: latest.cores),
                                                rollup: rollup, raw: rawValue)
        } else {
            let reading = PerfCounters.rawReading(spec, context(snapshot: nil, cores: []))
            values = PerfCounters.values(spec, old: lastSystemReading, new: reading, mode: rawValue ? .raw : .formatted)
            lastSystemReading = reading
        }
        let result = select(values, spec: spec)
        cachedResult = result
        rawString = result.1
        return result.0
    }

    private func context(snapshot: ProcessSnapshot?, cores: [CoreTicks]) -> PerfCounters.Context {
        PerfCounters.Context(system: skin.system, sensors: HardwareSensors.source(for: skin), snapshot: snapshot,
                             cores: cores, time: ProcessInfo.processInfo.systemUptime)
    }

    static func values(_ spec: PerfCounterSpec, previous: ProcessSnapshot?, latest: ProcessSnapshot,
                       context: PerfCounters.Context, rollup: Bool, raw: Bool) -> [PerfValue] {
        let mode: PerfCounters.Mode = raw ? .raw : .formatted
        if spec.isProcessField {
            return PerfCounters.processValues(spec, old: previous, new: latest, mode: mode, rollup: rollup)
        }
        var newContext = context
        newContext.snapshot = latest
        newContext.cores = latest.cores
        newContext.time = latest.time
        let new = PerfCounters.rawReading(spec, newContext)
        var old: PerfCounters.RawReading?
        if let previous {
            var oldContext = context
            oldContext.snapshot = previous
            oldContext.cores = previous.cores
            oldContext.time = previous.time
            old = PerfCounters.rawReading(spec, oldContext)
        }
        return PerfCounters.values(spec, old: old, new: new, mode: mode)
    }

    /// Applies Percent, the lists, then Name / Index. Returns the number and string values.
    func select(_ all: [PerfValue], spec: PerfCounterSpec) -> (Double, String) {
        var values = all
        if percent {
            guard let total = values.first(where: { $0.name == "_Total" })?.value, total > 0 else {
                report("percent", "UsageMonitor [\(name)]: Percent=1 needs a _Total instance; the value is 0")
                return (0, index == 0 ? "Total" : index == -1 ? "Average" : "")
            }
            values = values.map { PerfValue(name: $0.name, value: $0.value / total * 100) }
        }
        func matches(_ list: [String], _ name: String) -> Bool {
            list.contains { $0 == name || $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        if let whitelist {
            values = values.filter { matches(whitelist, $0.name) }
        } else if !blacklist.isEmpty {
            values = values.filter { !matches(blacklist, $0.name) }
        }
        func label(_ v: PerfValue) -> String {
            if pidToName, spec.field == .processPid,
               let n = ProcessNames.name(of: pid_t(truncatingIfNeeded: Int(v.value.clamped(0, 2e9)))) {
                return n
            }
            return v.name
        }
        if let instanceName {
            guard let v = PerfCounters.find(instanceName, in: values, category: spec.category) else {
                return (0, instanceName)
            }
            return (v.value, label(v))
        }
        switch index {
        case 0:
            return (values.reduce(0) { $0 + $1.value }, "Total")
        case -1:
            return (values.isEmpty ? 0 : values.reduce(0) { $0 + $1.value } / Double(values.count), "Average")
        default:
            let sorted = values.filter { $0.value > 0 }.sorted {
                $0.value != $1.value ? $0.value > $1.value : $0.name < $1.name
            }
            guard index - 1 < sorted.count else { return (0, "") }
            let v = sorted[index - 1]
            return (v.value, label(v))
        }
    }

    private func report(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        skin.log(message, level: .notice)
    }
}

// MARK: - PerfMon

/// `Plugin=PerfMon` (deprecated): `PerfMonObject`, `PerfMonCounter`, `PerfMonInstance`, `PerfMonDifference`.
/// The value is the stored ("raw") counter value — with `PerfMonDifference=1` (default) its change since the
/// measure's previous update, e.g. bytes transferred since then for "Disk Bytes/sec", or 100 ns of idle time for
/// Processor "% Processor Time" (an inverse timer, hence skins' `InvertMeasure=1`). An empty instance means `_Total`
/// (judgment). Processor counters are read at each update; process-based ones from the once-a-second sample (an
/// update that sees no new sample keeps its value). The range tracks the observed values.
public final class PerfMonMeasure: Measure, PluginLifecycle {
    private var spec: PerfCounterSpec?
    private var instance = ""
    private var difference = true
    private var subscribed = false
    private var lastReading: PerfCounters.RawReading?
    private var lastSnapshot: ProcessSnapshot?
    private var lastValue = 0.0
    private var reported = false

    override var tracksValueRange: Bool { true }

    deinit {
        if subscribed { ProcessSampler.shared.unsubscribe(id: ObjectIdentifier(self)) }
    }

    public func skinWillClose() {
        if subscribed {
            subscribed = false
            ProcessSampler.shared.unsubscribe(self)
        }
    }

    public override func readMeasureOptions() {
        let object = string("PerfMonObject").trimmingCharacters(in: .whitespaces)
        let counter = string("PerfMonCounter").trimmingCharacters(in: .whitespaces)
        let newSpec = PerfCounters.spec(category: object, counter: counter)
        if newSpec == nil && !reported {
            reported = true
            skin.log("PerfMon [\(name)]: counter \"\(object)\\\(counter)\" is not available on macOS; the value is 0",
                     level: .notice)
            skin.addIssue("PerfMon counter \(object)\\\(counter) is not available on macOS")
        }
        if newSpec != spec {
            spec = newSpec
            lastReading = nil
            lastSnapshot = nil
        }
        var i = string("PerfMonInstance").trimmingCharacters(in: .whitespaces)
        if i.isEmpty { i = "_Total" }
        instance = i
        difference = bool("PerfMonDifference", true)
        let needsSampler = spec?.needsProcesses == true
        if needsSampler && !subscribed {
            subscribed = true
            ProcessSampler.shared.subscribe(self)
        } else if !needsSampler && subscribed {
            subscribed = false
            ProcessSampler.shared.unsubscribe(self)
        }
    }

    public override func computeValue() -> Double {
        guard let spec else { return 0 }
        let mode: PerfCounters.Mode = difference ? .rawDelta : .raw
        let values: [PerfValue]
        if spec.needsProcesses {
            guard let latest = ProcessSampler.shared.samples().latest else { return lastValue }
            if let lastSnapshot, lastSnapshot.serial == latest.serial { return lastValue }
            if spec.isProcessField {
                values = PerfCounters.processValues(spec, old: lastSnapshot, new: latest, mode: mode, rollup: false)
            } else {
                let ctx = PerfCounters.Context(system: skin.system, sensors: HardwareSensors.source(for: skin),
                                               snapshot: latest, cores: latest.cores, time: latest.time)
                let reading = PerfCounters.rawReading(spec, ctx)
                values = PerfCounters.values(spec, old: lastReading, new: reading, mode: mode)
                lastReading = reading
            }
            lastSnapshot = latest
        } else {
            let ctx = PerfCounters.Context(system: skin.system, sensors: HardwareSensors.source(for: skin),
                                           snapshot: nil, cores: spec.usesCores ? ProcessorTicks.read() : [],
                                           time: ProcessInfo.processInfo.systemUptime)
            let reading = PerfCounters.rawReading(spec, ctx)
            values = PerfCounters.values(spec, old: lastReading, new: reading, mode: mode)
            lastReading = reading
        }
        let found = spec.category.isSingleInstance
            ? values.first
            : (PerfCounters.find(instance, in: values, category: spec.category)
               ?? (spec.category == .networkInterface || spec.category == .networkAdapter
                   ? PerfValue(name: instance, value: values.reduce(0) { $0 + $1.value }) : nil))
        lastValue = found?.value ?? 0
        return lastValue
    }
}

// MARK: - AdvancedCPU

/// `Plugin=AdvancedCPU` (deprecated): CPU time used by processes since the measure's previous update, in 100 ns units
/// (the unit of Windows' process time counters — skins divide by cores × 100000 × seconds to get percent, or set
/// MaxValue to an AdvancedCPU measure without CPUInclude/CPUExclude, which counts the whole machine incl. "Idle").
/// - `CPUInclude` (`;`-separated, overrides CPUExclude) / `CPUExclude` process names, case-insensitive, `.exe` ignored;
///   "Idle" is the idle time of all cores, "System" the processes of other users (not readable without privileges).
/// - `TopProcess=1`: the value of the busiest process; `TopProcess=2`: its name as the string (the number stays the
///   TopProcess=0 total).
/// - Sampled once a second in the background; the value is the latest sample's CPU rate × the real time since the
///   measure's previous update (so it matches the skin's interval even though the two clocks are not in step).
public final class AdvancedCPUMeasure: Measure, PluginLifecycle {
    private var include: Set<String>?
    private var exclude: Set<String> = []
    private var topProcess = 0
    private var lastSnapshot: ProcessSnapshot?
    private var lastResult: (Double, String?) = (0, nil)
    private var subscribed = false

    override var tracksValueRange: Bool { true }

    deinit {
        if subscribed { ProcessSampler.shared.unsubscribe(id: ObjectIdentifier(self)) }
    }

    public func skinWillClose() {
        if subscribed {
            subscribed = false
            ProcessSampler.shared.unsubscribe(self)
        }
    }

    static func nameSet(_ list: String) -> Set<String> {
        Set(list.split(separator: ";").map { ProcessNames.normalized(String($0)) }.filter { !$0.isEmpty })
    }

    public override func readMeasureOptions() {
        let inc = string("CPUInclude")
        include = inc.trimmingCharacters(in: .whitespaces).isEmpty ? nil : AdvancedCPUMeasure.nameSet(inc)
        exclude = AdvancedCPUMeasure.nameSet(string("CPUExclude"))
        topProcess = min(max(int("TopProcess", 0), 0), 2)
        if !subscribed {
            subscribed = true
            ProcessSampler.shared.subscribe(self)
        }
    }

    /// Monotonic clock (seconds); tests may replace it.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var lastUpdate: TimeInterval?
    /// CPU time per second of the latest sampled interval, and the top process.
    private var rate: (Double, String?)?

    /// The CPU time of the latest sampled interval, scaled to the real time since this measure's previous update: the
    /// once-a-second sampler and the skin's timer are not in step, and skins divide by their nominal interval.
    public override func computeValue() -> Double {
        let now = clock()
        let elapsed = lastUpdate.map { min(max(now - $0, 0), 3600) }
        lastUpdate = now
        let samples = ProcessSampler.shared.samples()
        if let latest = samples.latest, lastSnapshot?.serial != latest.serial {
            // The first value uses the sampler's own previous sample, so it does not wait for a second update.
            if let base = lastSnapshot ?? samples.previous {
                let interval = ProcessCPUInterval(from: base, to: latest)
                if interval.seconds > 0 {
                    let r = AdvancedCPUMeasure.evaluate(interval, include: include, exclude: exclude,
                                                        topProcess: topProcess)
                    rate = (r.0 / interval.seconds, r.1)
                    if elapsed == nil { lastResult = r }
                }
            }
            lastSnapshot = latest
        }
        if let rate, let elapsed { lastResult = (rate.0 * elapsed, rate.1) }
        rawString = topProcess == 2 ? (lastResult.1 ?? "") : nil
        return lastResult.0
    }

    /// (number, top process name) for one interval.
    static func evaluate(_ interval: ProcessCPUInterval, include: Set<String>?, exclude: Set<String>,
                         topProcess: Int) -> (Double, String?) {
        let own = ProcessNames.normalized(ProcessInfo.processInfo.processName)
        func key(_ name: String) -> String { ProcessNames.normalized(name) }
        func selected(_ name: String) -> Bool {
            let k = key(name)
            if let include { return include.contains(k) || (include.contains("rainmeter") && k == own) }
            return !exclude.contains(k) && !(exclude.contains("rainmeter") && k == own)
        }
        let entries = interval.entries.filter { selected($0.name) }
        let total = entries.reduce(0) { $0 + $1.cpu }
        let top = entries.max { $0.cpu != $1.cpu ? $0.cpu < $1.cpu : $0.name > $1.name }
        switch topProcess {
        case 1: return (top?.cpu ?? 0, top?.name)
        case 2: return (total, top?.name)
        default: return (total, top?.name)
        }
    }
}
