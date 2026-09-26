import DesksetCore
import Foundation
import IOKit

// Power and clock frequencies on Apple silicon, from IOReport (the private libIOReport that powermetrics and
// Activity Monitor's energy figures use), looked up with dlsym: when a macOS release renames or drops a symbol, the
// sampler reports nothing instead of failing to load.
//
// - "Energy Model": energy per interval of the CPU, GPU, Neural Engine and memory; energy ÷ seconds = watts.
// - "CPU Core Performance States" / "GPU Performance States": how long each core (and the GPU) spent in each clock
//   state since the previous sample. The states' clocks and voltages are the tables in the device tree's `pmgr` node
//   (`voltage-states1` efficiency cores, `…5` performance cores, `…9` GPU: pairs of 32-bit words). The average clock
//   of a core is the residency-weighted clock of its active states.
// Values need two samples, so the first sample only subscribes; each later one covers the time since the one before.

/// A clock-state table: MHz per active state (lowest first), and the voltage each state asks for (V) when known.
struct DVFSTable: Equatable {
    var frequencies: [Double]
    var voltages: [Double]?

    /// From a `voltage-states…` property: pairs of little-endian 32-bit words (frequency, millivolts). The GPU
    /// table's leading "off" entry (frequency 0) is dropped. Frequencies are in Hz, or in kHz in the `-sram` tables of
    /// newer chips: values below 20 000 000 are read as kHz.
    static func parse(_ data: Data) -> (frequencies: [Double], millivolts: [Double])? {
        guard data.count >= 8, data.count % 8 == 0 else { return nil }
        var words: [UInt32] = []
        data.withUnsafeBytes { raw in
            for i in stride(from: 0, to: data.count, by: 4) {
                words.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)))
            }
        }
        var frequencies: [Double] = [], millivolts: [Double] = []
        for i in stride(from: 0, to: words.count - 1, by: 2) where words[i] > 0 {
            frequencies.append(Double(words[i]))
            millivolts.append(Double(words[i + 1]))
        }
        guard let top = frequencies.max(), top > 0 else { return nil }
        let divisor: Double = top < 20_000_000 ? 1_000 : 1_000_000
        return (frequencies.map { $0 / divisor }, millivolts)
    }

    enum Unit: String {
        case efficiency, performance, gpu

        /// The table's number in `voltage-statesN`.
        var tableNumber: Int {
            switch self {
            case .efficiency: return 1
            case .performance: return 5
            case .gpu: return 9
            }
        }

        /// Clocks a table of this unit can have (MHz).
        var plausible: ClosedRange<Double> { self == .gpu ? 100...4000 : 300...8000 }
    }

    /// The table for `unit` with `states` active states, from the `pmgr` properties: `voltage-statesN-sram` (newer
    /// chips keep the clocks there) or `voltage-statesN` for the clocks, `voltage-statesN` for the voltages; when
    /// that table does not have `states` entries, any table that does.
    static func table(for unit: Unit, states: Int, properties: [String: Data]) -> DVFSTable? {
        func candidate(_ number: Int) -> DVFSTable? {
            let base = properties["voltage-states\(number)"].flatMap(parse)
            let sram = properties["voltage-states\(number)-sram"].flatMap(parse)
            func fits(_ t: (frequencies: [Double], millivolts: [Double])?) -> Bool {
                guard let t, t.frequencies.count == states else { return false }
                return t.frequencies.allSatisfy { unit.plausible.contains($0) }
            }
            guard let clocks = fits(sram) ? sram : fits(base) ? base : nil else { return nil }
            let volts = [base, sram].compactMap { $0 }.first { t in
                t.millivolts.count == states && t.millivolts.allSatisfy { (300...1500).contains($0) }
            }
            return DVFSTable(frequencies: clocks.frequencies, voltages: volts.map { $0.millivolts.map { $0 / 1000 } })
        }
        if let t = candidate(unit.tableNumber) { return t }
        let numbers = properties.keys.compactMap { key -> Int? in
            guard key.hasPrefix("voltage-states") else { return nil }
            return Int(key.dropFirst("voltage-states".count).split(separator: "-").first ?? "")
        }
        for n in Set(numbers).sorted() where n != unit.tableNumber {
            if let t = candidate(n) { return t }
        }
        return nil
    }
}

/// One channel's residencies since the previous sample.
struct DVFSResidency: Equatable {
    var name: String
    var states: [(name: String, residency: Int64)]

    static func == (a: DVFSResidency, b: DVFSResidency) -> Bool {
        a.name == b.name && a.states.map(\.name) == b.states.map(\.name) && a.states.map(\.residency) == b.states.map(\.residency)
    }

    /// The states that run (not IDLE, DOWN or OFF), in order.
    var active: [(name: String, residency: Int64)] {
        states.filter { !["IDLE", "DOWN", "OFF"].contains($0.name.uppercased()) }
    }
}

enum IOReportMath {
    /// Residency-weighted clock (MHz) and voltage (V) of `channels` together over their active time; a unit that did
    /// not run at all is at its lowest clock, with no voltage. nil when the states do not match the table.
    static func average(_ channels: [DVFSResidency], table: DVFSTable) -> (mhz: Double, volts: Double?, activeTime: Int64)? {
        guard !channels.isEmpty, let lowest = table.frequencies.min() else { return nil }
        var busy: Int64 = 0
        var clock = 0.0, volts = 0.0
        for channel in channels {
            let active = channel.active
            guard active.count == table.frequencies.count else { return nil }
            for (i, state) in active.enumerated() where state.residency > 0 {
                busy += state.residency
                clock += Double(state.residency) * table.frequencies[i]
                if let v = table.voltages, i < v.count { volts += Double(state.residency) * v[i] }
            }
        }
        guard busy > 0 else { return (lowest, nil, 0) }
        return (clock / Double(busy), table.voltages == nil ? nil : volts / Double(busy), busy)
    }

    /// Joules for an energy channel's value in its unit ("mJ", "uJ", "µJ", "nJ", "J"); nil for other units.
    static func joules(_ value: Int64, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "mJ": return Double(value) / 1e3
        case "uJ", "µJ": return Double(value) / 1e6
        case "nJ": return Double(value) / 1e9
        case "J": return Double(value)
        default: return nil
        }
    }

    /// Watts of the catalog's power keys from the energy channels (joules by channel name) over `seconds`. Channel
    /// names by chip: "CPU Energy", "ANE", "DRAM" (M1…M4, Pro); "ANE0", "ANE1"… (Max); one per die on Ultra chips:
    /// "DIE_0_CPU Energy", "DIE_1_CPU Energy", "ANE0_0", "ANE0_1", "DRAM0_1"…, added up.
    static func power(_ joules: [String: Double], seconds: Double) -> [String: Double] {
        guard seconds > 0 else { return [:] }
        func isNumber(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) } }
        func total(_ match: (String) -> Bool) -> Double? {
            let parts = joules.filter { match($0.key) }
            return parts.isEmpty ? nil : parts.values.reduce(0, +)
        }
        /// "ANE", or the numbered channels: "ANE0", "ANE1", "ANE0_1" (not "ANE_SRAM" or "ANEX").
        func numbered(_ prefix: String) -> Double? {
            joules[prefix] ?? total { name in
                guard name.hasPrefix(prefix) else { return false }
                let parts = name.dropFirst(prefix.count).split(separator: "_", omittingEmptySubsequences: false)
                return (1...2).contains(parts.count) && parts.allSatisfy(isNumber)
            }
        }
        /// "CPU Energy", else the dies' "DIE_<n>_CPU Energy".
        let cpu = joules["CPU Energy"] ?? total { name in
            guard name.hasPrefix("DIE_"), name.hasSuffix("_CPU Energy") else { return false }
            return isNumber(name.dropFirst("DIE_".count).dropLast("_CPU Energy".count))
        }
        var result: [String: Double] = [:]
        let picks: [(String, Double?)] = [
            (SensorKeys.powerCPU, cpu),
            (SensorKeys.powerGPU, joules["GPU Energy"] ?? joules["GPU"]),
            (SensorKeys.powerANE, numbered("ANE")),
            (SensorKeys.powerDRAM, numbered("DRAM")),
        ]
        for (key, j) in picks {
            if let j, j >= 0 { result[key] = j / seconds }
        }
        return result
    }

    /// The per-core channels ("ECPU000", "PCPU140"…) of each logical CPU (0-based): the channels of each cluster type
    /// in name order go to that type's cores in logical order. Empty when the counts do not match.
    static func coreChannels(names: [String], coreTypes: [CoreType]) -> [Int: String] {
        var result: [Int: String] = [:]
        for (type, prefix) in [(CoreType.efficiency, "E"), (.performance, "P")] {
            let channels = names.filter { $0.uppercased().hasPrefix(prefix + "CPU") }.sorted()
            let cores = coreTypes.indices.filter { coreTypes[$0] == type }
            guard channels.count == cores.count else { return [:] }
            for (core, channel) in zip(cores, channels) { result[core] = channel }
        }
        return result.count == coreTypes.count ? result : [:]
    }

    /// Catalog values from one interval: power, per-core / per-cluster / GPU clocks, the CPU's voltage. `cores`
    /// lists the channels in "CPU Core Performance States", `gpu` those in "GPU Performance States".
    static func reading(joules: [String: Double], seconds: Double, cores: [DVFSResidency], gpu: [DVFSResidency],
                        coreTypes: [CoreType], tables: [String: Data]) -> SensorGroupReading {
        var reading = SensorGroupReading()
        let power = self.power(joules, seconds: seconds)
        for (key, label) in [(SensorKeys.powerCPU, "Power: CPU"), (SensorKeys.powerGPU, "Power: GPU"),
                             (SensorKeys.powerANE, "Power: Neural Engine"), (SensorKeys.powerDRAM, "Power: memory")] {
            guard let w = power[key] else { continue }
            reading.add(SensorInfo(key: key, label: label, kind: .power, source: "IOReport Energy Model"), w)
        }
        let byName = Dictionary(cores.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var clusterValues: [(unit: DVFSTable.Unit, mhz: Double)] = []
        var voltTime: Int64 = 0, voltSum = 0.0
        for (unit, prefix) in [(DVFSTable.Unit.performance, "P"), (.efficiency, "E")] {
            let channels = cores.filter { $0.name.uppercased().hasPrefix(prefix + "CPU") }
            guard let states = channels.first?.active.count,
                  let table = DVFSTable.table(for: unit, states: states, properties: tables),
                  let avg = average(channels, table: table) else { continue }
            let key = unit == .performance ? SensorKeys.frequencyPerformance : SensorKeys.frequencyEfficiency
            let label = unit == .performance ? "CPU performance cores clock" : "CPU efficiency cores clock"
            reading.add(SensorInfo(key: key, label: label, kind: .frequency, minimum: table.frequencies.min(),
                                   maximum: table.frequencies.max(), source: "IOReport CPU Core Performance States"),
                        avg.mhz)
            clusterValues.append((unit, avg.mhz))
            if let v = avg.volts {
                voltSum += v * Double(avg.activeTime)
                voltTime += avg.activeTime
            }
            // The cores of this cluster type.
            for (core, name) in coreChannels(names: cores.map(\.name), coreTypes: coreTypes).sorted(by: { $0.key < $1.key }) {
                guard coreTypes[core] == (unit == .performance ? .performance : .efficiency), let channel = byName[name],
                      let v = average([channel], table: table) else { continue }
                reading.add(SensorInfo(key: SensorKeys.frequencyCore(core + 1), label: "CPU core \(core + 1) clock",
                                       kind: .frequency, minimum: table.frequencies.min(),
                                       maximum: table.frequencies.max(), source: "IOReport \(name)"), v.mhz)
            }
        }
        if let fastest = clusterValues.max(by: { $0.mhz < $1.mhz }) {
            let tables = clusterValues.compactMap { c in
                reading.infos.first { $0.key == (c.unit == .performance ? SensorKeys.frequencyPerformance
                                                 : SensorKeys.frequencyEfficiency) }
            }
            reading.add(SensorInfo(key: SensorKeys.frequencyCPU, label: "CPU clock (fastest cluster)", kind: .frequency,
                                   minimum: tables.compactMap(\.minimum).min(), maximum: tables.compactMap(\.maximum).max(),
                                   source: "IOReport CPU Core Performance States"), fastest.mhz)
        }
        if voltTime > 0 {
            reading.add(SensorInfo(key: SensorKeys.voltageCPU, label: "CPU voltage (requested, while running)",
                                   kind: .voltage, source: "IOReport and the pmgr voltage tables"), voltSum / Double(voltTime))
        }
        if let channel = gpu.first, let table = DVFSTable.table(for: .gpu, states: channel.active.count, properties: tables),
           let avg = average([channel], table: table) {
            reading.add(SensorInfo(key: SensorKeys.frequencyGPU, label: "GPU clock", kind: .frequency,
                                   minimum: table.frequencies.min(), maximum: table.frequencies.max(),
                                   source: "IOReport GPU Performance States"), avg.mhz)
        }
        // Per-core keys in core order after the cluster keys (catalog order).
        reading.infos.sort { SensorGroupReading.order($0.key) < SensorGroupReading.order($1.key) }
        return reading
    }
}

/// Which two samples an IOReport reading measures between. Every sample is stamped when it was taken, and a reading
/// covers the time from the base sample to a new one. The first sample only becomes the base; one taken less than
/// `minimum` after the base (two refreshes in quick succession) leaves the base alone, and the last reading stands.
struct IOReportTimeline<Sample> {
    static var minimum: TimeInterval { 0.05 }

    enum Step {
        case first
        case tooSoon
        case interval(from: Sample, seconds: TimeInterval)
    }

    private(set) var base: (sample: Sample, time: TimeInterval)?

    mutating func add(_ sample: Sample, at time: TimeInterval) -> Step {
        guard let base else {
            self.base = (sample, time)
            return .first
        }
        let seconds = time - base.time
        guard seconds > Self.minimum else { return .tooSoon }
        self.base = (sample, time)
        return .interval(from: base.sample, seconds: seconds)
    }
}

/// A cluster type of a logical CPU.
enum CoreType: Equatable {
    case performance, efficiency, unknown
}

/// The live IOReport subscription. Not thread-safe: the sensor service uses it on its queue only.
final class IOReportSampler {
    private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64)
        -> Unmanaged<CFMutableDictionary>?
    private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
        UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> Unmanaged<CFTypeRef>?
    private typealias CreateSamples = @convention(c) (CFTypeRef, CFMutableDictionary, CFTypeRef?)
        -> Unmanaged<CFDictionary>?
    private typealias CreateSamplesDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?)
        -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelInteger = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias StateCount = @convention(c) (CFDictionary) -> Int32
    private typealias StateName = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private struct Functions {
        let copyChannels: CopyChannelsInGroup
        let merge: MergeChannels
        let subscribe: CreateSubscription
        let samples: CreateSamples
        let delta: CreateSamplesDelta
        let group: ChannelString
        let subgroup: ChannelString
        let name: ChannelString
        let unit: ChannelString
        let integer: ChannelInteger
        let stateCount: StateCount
        let stateName: StateName
        let residency: ChannelInteger

        static let shared: Functions? = {
            guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
            func fn<T>(_ name: String, _: T.Type) -> T? { dlsym(lib, name).map { unsafeBitCast($0, to: T.self) } }
            guard let copy = fn("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
                  let merge = fn("IOReportMergeChannels", MergeChannels.self),
                  let subscribe = fn("IOReportCreateSubscription", CreateSubscription.self),
                  let samples = fn("IOReportCreateSamples", CreateSamples.self),
                  let delta = fn("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
                  let group = fn("IOReportChannelGetGroup", ChannelString.self),
                  let subgroup = fn("IOReportChannelGetSubGroup", ChannelString.self),
                  let name = fn("IOReportChannelGetChannelName", ChannelString.self),
                  let unit = fn("IOReportChannelGetUnitLabel", ChannelString.self),
                  let integer = fn("IOReportSimpleGetIntegerValue", ChannelInteger.self),
                  let stateCount = fn("IOReportStateGetCount", StateCount.self),
                  let stateName = fn("IOReportStateGetNameForIndex", StateName.self),
                  let residency = fn("IOReportStateGetResidency", ChannelInteger.self) else { return nil }
            return Functions(copyChannels: copy, merge: merge, subscribe: subscribe, samples: samples, delta: delta,
                             group: group, subgroup: subgroup, name: name, unit: unit, integer: integer,
                             stateCount: stateCount, stateName: stateName, residency: residency)
        }()
    }

    private let functions: Functions
    private let subscription: CFTypeRef
    private let channels: CFMutableDictionary
    private var timeline = IOReportTimeline<CFDictionary>()
    private var last: SensorGroupReading?
    private let coreTypes: [CoreType]
    private let tables: [String: Data]
    private let clock: () -> TimeInterval

    /// nil when libIOReport, its functions or the channels are missing (Intel Macs, virtual machines, a future macOS).
    /// `clock` stamps the samples.
    init?(coreTypes: [CoreType], clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        guard let f = Functions.shared,
              let energy = f.copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        for (group, subgroup) in [("CPU Stats", "CPU Core Performance States"), ("GPU Stats", "GPU Performance States")] {
            if let more = f.copyChannels(group as CFString, subgroup as CFString, 0, 0, 0)?.takeRetainedValue() {
                f.merge(energy, more, nil)
            }
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let sub = f.subscribe(nil, energy, &subscribed, 0, nil)?.takeRetainedValue(),
              let chosen = subscribed?.takeRetainedValue() else { return nil }
        functions = f
        subscription = sub
        channels = chosen
        self.coreTypes = coreTypes
        self.clock = clock
        tables = IOReportSampler.pmgrTables()
    }

    /// Takes a sample; the values cover the time since the previous one (none the first time). A sample taken too
    /// soon after the previous one answers with the last reading; a failed one with the last reading's sensors, without
    /// values.
    func sample() -> SensorGroupReading? {
        let f = functions
        guard let current = f.samples(subscription, channels, nil)?.takeRetainedValue() else { return unavailable() }
        let seconds: TimeInterval, delta: CFDictionary
        switch timeline.add(current, at: clock()) {
        case .first:
            return nil
        case .tooSoon:
            return last
        case .interval(let from, let s):
            guard let d = f.delta(from, current, nil)?.takeRetainedValue() else { return unavailable() }
            seconds = s
            delta = d
        }
        guard let items = (delta as NSDictionary)["IOReportChannels"] as? [NSDictionary] else { return unavailable() }
        var joules: [String: Double] = [:]
        var cores: [DVFSResidency] = [], gpu: [DVFSResidency] = []
        for item in items {
            let channel = item as CFDictionary
            let group = f.group(channel)?.takeUnretainedValue() as String? ?? ""
            let name = f.name(channel)?.takeUnretainedValue() as String? ?? ""
            if group == "Energy Model" {
                let unit = f.unit(channel)?.takeUnretainedValue() as String? ?? ""
                if let j = IOReportMath.joules(f.integer(channel, 0), unit: unit) { joules[name, default: 0] += j }
                continue
            }
            let subgroup = f.subgroup(channel)?.takeUnretainedValue() as String? ?? ""
            let count = min(max(Int(f.stateCount(channel)), 0), 256)
            let states = (0..<count).map { i -> (name: String, residency: Int64) in
                (f.stateName(channel, Int32(i))?.takeUnretainedValue() as String? ?? "", f.residency(channel, Int32(i)))
            }
            if subgroup == "CPU Core Performance States" {
                cores.append(DVFSResidency(name: name, states: states))
            } else if subgroup == "GPU Performance States" {
                gpu.append(DVFSResidency(name: name, states: states))
            }
        }
        let reading = IOReportMath.reading(joules: joules, seconds: seconds, cores: cores, gpu: gpu,
                                           coreTypes: coreTypes, tables: tables)
        last = reading
        return reading
    }

    private func unavailable() -> SensorGroupReading? {
        last.map { SensorGroupReading(infos: $0.infos) }
    }

    /// The `voltage-states…` properties of the device tree's power manager.
    static func pmgrTables() -> [String: Data] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator)
                == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        var result: [String: Data] = [:]
        var visited = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            visited += 1
            guard visited < 4096, result.isEmpty else { continue }
            var name = [CChar](repeating: 0, count: 128)
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS, String(cString: name) == "pmgr" else { continue }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = properties?.takeRetainedValue() as? [String: Any] else { continue }
            for (key, value) in dict where key.hasPrefix("voltage-states") {
                if let data = value as? Data { result[key] = data }
            }
        }
        return result
    }

    /// The cluster type of each logical CPU, from the device tree (`/cpus/cpuN`: `logical-cpu-id`, `cluster-type`
    /// "E" or "P"); unknown for Macs without it.
    static func coreTypes() -> [CoreType] {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != 0 else { return [] }
        defer { IOObjectRelease(cpus) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var types: [Int: CoreType] = [:]
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard types.count < 1024,
                  let id = IORegistryEntryCreateCFProperty(entry, "logical-cpu-id" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber else { continue }
            let raw = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data
            types[id.intValue] = raw.flatMap { SensorGroupReading.coreType(clusterType: $0) } ?? .unknown
        }
        guard !types.isEmpty, types.keys.sorted() == Array(0..<types.count) else { return [] }
        return (0..<types.count).map { types[$0] ?? .unknown }
    }
}
