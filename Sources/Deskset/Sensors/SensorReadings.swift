import DesksetCore
import Foundation

// Catalog entries and values from raw readings (SMC keys, HID sensors, IOKit dictionaries). Pure functions: the self
// tests feed them fixture tables of M-series and Intel Macs.

/// Sensors of one group, as one sample found them.
struct SensorGroupReading {
    var infos: [SensorInfo] = []
    var values: [String: Double] = [:]

    /// Adds a sensor (once) and its value (nil: the sensor exists but has no reading this time).
    mutating func add(_ info: SensorInfo, _ value: Double?) {
        if !infos.contains(where: { $0.key == info.key }) { infos.append(info) }
        if let value, value.isFinite { values[info.key] = value }
    }

    /// The catalog position of a key: `SensorKeys.common`'s order, where the entries for number 1 of a numbered
    /// family stand for every number: fan 1 and its minimum, maximum and target, then fan 2 and its…; core 1, core 2…
    static func order(_ key: String) -> Int {
        let common = SensorKeys.common
        var parts = key.split(separator: ".").map(String.init)
        guard let i = parts.firstIndex(where: { Int($0) != nil }) else {
            return (common.firstIndex { $0.key == key } ?? common.count) * 1_000_000
        }
        let number = min(Int(parts[i]) ?? 0, 999)
        parts[i] = "1"
        let variant = common.firstIndex { $0.key == parts.joined(separator: ".") } ?? common.count
        // The family: the first entry with the same words before the number ("fan.1", "cpu.core.1").
        let head = parts[..<i].joined(separator: ".") + ".1"
        let family = common.firstIndex { $0.key == head || $0.key.hasPrefix(head + ".") } ?? variant
        return family * 1_000_000 + number * 1_000 + variant
    }

    /// `cluster-type` ("E" / "P", a C string) → the core type.
    static func coreType(clusterType: Data) -> CoreType? {
        switch clusterType.first {
        case UInt8(ascii: "E"): return .efficiency
        case UInt8(ascii: "P"): return .performance
        default: return nil
        }
    }
}

/// One temperature sensor's reading.
struct TemperatureReading: Equatable {
    var name: String
    var role: TemperatureRole
    var celsius: Double
}

enum SensorReadings {
    // MARK: Temperatures

    /// The temperature group from classified readings (invalid ones already dropped; `present` lists the roles that
    /// have sensors even when none of them read validly this time, so their catalog entries stay):
    /// - `cpu` the hottest CPU reading, `cpu.performance` / `cpu.efficiency` the hottest of each cluster;
    /// - `cpu.core.N`: on Apple silicon the hottest reading of the core's cluster (`coreTypes`, from the device tree),
    ///   `cpu` when the clusters share their sensors; on Intel the core's own sensor (`intelCoreKeys`), else `cpu`;
    /// - `gpu`, `soc`, `battery`, `ssd`: the hottest reading of each.
    /// On Apple silicon a CPU cluster or the GPU whose sensors all read "powered down" (the GPU's do for minutes while
    /// it is idle) sits at the rest of the chip's temperature: it reports `soc` then.
    static func temperatures(_ readings: [TemperatureReading], present: Set<TemperatureRole>, family: ChipFamily,
                             coreTypes: [CoreType], physicalCores: Int, source: String) -> SensorGroupReading {
        var reading = SensorGroupReading()
        let chip = family.isAppleSilicon ? readings.filter { $0.role == .soc }.map(\.celsius).max() : nil
        func hottest(_ match: (TemperatureRole) -> Bool) -> Double? {
            readings.filter { match($0.role) }.map(\.celsius).max()
        }
        /// For the CPU clusters and the GPU: the chip's temperature while they are powered down.
        func hottestOrChip(_ match: (TemperatureRole) -> Bool) -> Double? { hottest(match) ?? chip }
        func names(_ match: (TemperatureRole) -> Bool) -> String {
            let list = readings.filter { match($0.role) }.map(\.name)
            guard !list.isEmpty else { return source }
            let shown = list.prefix(4).joined(separator: " ")
            return "\(source) \(shown)\(list.count > 4 ? " … (\(list.count))" : "")"
        }
        let hasCPU = present.contains { $0.isCPU }
        if hasCPU {
            reading.add(SensorInfo(key: SensorKeys.cpu, label: "CPU temperature (hottest sensor)", kind: .temperature,
                                   source: names { $0.isCPU }), hottestOrChip { $0.isCPU })
        }
        let performance = hottestOrChip { $0 == .cpuPerformance }, efficiency = hottestOrChip { $0 == .cpuEfficiency }
        if present.contains(.cpuPerformance) {
            reading.add(SensorInfo(key: SensorKeys.cpuPerformance, label: "CPU performance cores temperature",
                                   kind: .temperature, source: names { $0 == .cpuPerformance }), performance)
        }
        if present.contains(.cpuEfficiency) {
            reading.add(SensorInfo(key: SensorKeys.cpuEfficiency, label: "CPU efficiency cores temperature",
                                   kind: .temperature, source: names { $0 == .cpuEfficiency }), efficiency)
        }
        if hasCPU {
            let cpu = reading.values[SensorKeys.cpu]
            if family.isAppleSilicon {
                for (i, type) in coreTypes.enumerated() {
                    let value: Double?
                    let from: String
                    switch type {
                    case .performance where present.contains(.cpuPerformance):
                        value = performance; from = "its cluster (performance cores)"
                    case .efficiency where present.contains(.cpuEfficiency):
                        value = efficiency; from = "its cluster (efficiency cores)"
                    default:
                        value = cpu; from = "the hottest CPU sensor"
                    }
                    reading.add(SensorInfo(key: SensorKeys.cpuCore(i + 1), label: "CPU core \(i + 1) temperature",
                                           kind: .temperature, source: "\(source): \(from)"), value)
                }
            } else {
                let coreKeys = intelCoreKeys(present, physicalCores: physicalCores)
                for i in 0..<max(physicalCores, 0) {
                    let role = i < coreKeys.count ? TemperatureRole.cpuCore(coreKeys[i]) : nil
                    let own = role.flatMap { r in hottest { $0 == r } }
                    reading.add(SensorInfo(key: SensorKeys.cpuCore(i + 1), label: "CPU core \(i + 1) temperature",
                                           kind: .temperature,
                                           source: role.map { r in names { $0 == r } } ?? "\(source): the whole CPU"),
                                own ?? cpu)
                }
            }
        }
        let others: [(TemperatureRole, String, String)] = [
            (.gpu, SensorKeys.gpu, "GPU temperature"),
            (.soc, SensorKeys.soc, family.isAppleSilicon ? "Chip temperature (SoC)" : "Chipset temperature (PCH)"),
            (.battery, SensorKeys.battery, "Battery temperature"), (.ssd, SensorKeys.ssd, "SSD temperature"),
        ]
        for (role, key, label) in others where present.contains(role) {
            reading.add(SensorInfo(key: key, label: label, kind: .temperature, source: names { $0 == role }),
                        role == .gpu ? hottestOrChip { $0 == role } : hottest { $0 == role })
        }
        return reading
    }

    /// Intel: the digits of the core keys (`TC<d>C`) in core order. Macs number them from 1 (TC1C…TC4C on a
    /// 4-core MacBook Pro) or from 0, so core N is the N-th key present; where there is one key more than cores and
    /// it is TC0C (TC0C and TC1C…TC4C on a 4-core Mac), TC0C describes the whole CPU and the cores are TC1C….
    static func intelCoreKeys(_ present: Set<TemperatureRole>, physicalCores: Int) -> [Int] {
        var digits = present.compactMap { role -> Int? in
            if case .cpuCore(let d) = role { return d }
            return nil
        }.sorted()
        if digits.count > physicalCores, digits.first == 0 { digits.removeFirst() }
        return digits
    }

    /// Classifies and filters SMC readings (`values`: key → °C) into the temperature group.
    static func smcTemperatures(_ values: [String: Double], family: ChipFamily, coreTypes: [CoreType],
                                physicalCores: Int) -> SensorGroupReading {
        var readings: [TemperatureReading] = []
        var present: Set<TemperatureRole> = []
        for (key, celsius) in values.sorted(by: { $0.key < $1.key }) {
            guard let role = SensorClassification.role(ofSMCKey: key, family: family) else { continue }
            present.insert(role)
            if SensorClassification.isValid(celsius, role: role, family: family) {
                readings.append(TemperatureReading(name: key, role: role, celsius: celsius))
            }
        }
        return temperatures(readings, present: present, family: family, coreTypes: coreTypes,
                            physicalCores: physicalCores, source: "SMC")
    }

    /// The SMC keys the temperature group reads, from the SMC's key list (name → type): numeric `T…` keys with a
    /// role.
    static func temperatureKeys(_ keys: [String: SMCKeyInfo], family: ChipFamily) -> [String] {
        keys.filter { SMCValue.isNumeric($0.value.type) && SensorClassification.role(ofSMCKey: $0.key, family: family) != nil }
            .keys.sorted()
    }

    /// HID sensors (product name → °C, duplicates already merged) into the temperature group.
    static func hidTemperatures(_ sensors: [(name: String, celsius: Double)], family: ChipFamily,
                                coreTypes: [CoreType], physicalCores: Int) -> SensorGroupReading {
        var readings: [TemperatureReading] = []
        var present: Set<TemperatureRole> = []
        for sensor in sensors {
            guard let role = SensorClassification.role(ofHIDName: sensor.name) else { continue }
            present.insert(role)
            if SensorClassification.isValid(sensor.celsius, role: role, family: family) {
                readings.append(TemperatureReading(name: sensor.name, role: role, celsius: sensor.celsius))
            }
        }
        return temperatures(readings, present: present, family: family, coreTypes: coreTypes,
                            physicalCores: physicalCores, source: "HID")
    }

    // MARK: Fans and system power

    /// Fans from SMC keys: `FNum` fans, fan N (1-based) = `F<N-1>Ac` (speed), `…Mn`, `…Mx`, `…Tg` (minimum, maximum,
    /// target). A Mac without fans (FNum 0 or missing) has none. Speeds outside 0–20 000 RPM are not readings.
    static func fans(_ read: (String) -> Double?) -> SensorGroupReading {
        var reading = SensorGroupReading()
        let count = min(max(Int(read("FNum") ?? 0), 0), 16)
        func rpm(_ key: String) -> Double? {
            guard let v = read(key), v.isFinite, v >= 0, v < 20_000 else { return nil }
            return v
        }
        for i in 0..<count {
            let n = i + 1
            guard let actual = rpm("F\(i)Ac") else { continue }
            let minimum = rpm("F\(i)Mn"), maximum = rpm("F\(i)Mx").flatMap { $0 > 0 ? $0 : nil }
            reading.add(SensorInfo(key: SensorKeys.fan(n), label: "Fan \(n) speed", kind: .fan, minimum: minimum,
                                   maximum: maximum, source: "SMC F\(i)Ac"), actual)
            if let minimum {
                reading.add(SensorInfo(key: SensorKeys.fan(n, .minimum), label: "Fan \(n) minimum speed", kind: .fan,
                                       source: "SMC F\(i)Mn"), minimum)
            }
            if let maximum {
                reading.add(SensorInfo(key: SensorKeys.fan(n, .maximum), label: "Fan \(n) maximum speed", kind: .fan,
                                       source: "SMC F\(i)Mx"), maximum)
            }
            if let target = rpm("F\(i)Tg") {
                reading.add(SensorInfo(key: SensorKeys.fan(n, .target), label: "Fan \(n) target speed", kind: .fan,
                                       source: "SMC F\(i)Tg"), target)
            }
        }
        return reading
    }

    /// Whole-Mac power (`PSTR`) and the power adapter's input (`PDTR`), in watts.
    static func systemPower(_ read: (String) -> Double?) -> SensorGroupReading {
        var reading = SensorGroupReading()
        for (key, smc, label) in [(SensorKeys.powerSystem, "PSTR", "Power: whole Mac"),
                                  (SensorKeys.powerAdapter, "PDTR", "Power: from the adapter")] {
            guard let w = read(smc), w.isFinite, w >= 0, w < 5_000 else { continue }
            reading.add(SensorInfo(key: key, label: label, kind: .power, source: "SMC \(smc)"), w)
        }
        return reading
    }

    // MARK: GPU

    /// The GPU group from the `PerformanceStatistics` of each graphics accelerator: `Device Utilization %` →
    /// `gpu.usage` (the busiest GPU), `Renderer` / `Tiler Utilization %`, `In use system memory` (Apple silicon) or
    /// `vramUsedBytes` → `gpu.memory` (added up). A discrete GPU's `Temperature(C)`, `Fan Speed(%)`,
    /// `Core Clock(MHz)` and `Memory Clock(MHz)` fill `gpu`, `gpu.fan`, `frequency.gpu`, `frequency.gpu.memory` (Intel
    /// Macs; untested). Accelerators without statistics are skipped.
    static func gpu(_ statistics: [[String: Any]]) -> SensorGroupReading {
        var reading = SensorGroupReading()
        func number(_ d: [String: Any], _ key: String) -> Double? {
            guard let n = d[key] as? NSNumber else { return nil }
            let v = n.doubleValue
            return v.isFinite ? v : nil
        }
        let valid = statistics.filter { number($0, "Device Utilization %") != nil || number($0, "GPU Activity(%)") != nil }
        guard !valid.isEmpty else { return reading }
        func best(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            valid.compactMap { number($0, key) }.filter { range.contains($0) }.max()
        }
        let usage = valid.compactMap { number($0, "Device Utilization %") ?? number($0, "GPU Activity(%)") }
            .map { min(max($0, 0), 100) }.max()
        reading.add(SensorInfo(key: SensorKeys.gpuUsage, label: "GPU usage", kind: .percent,
                               source: "IOAccelerator PerformanceStatistics"), usage)
        if let r = best("Renderer Utilization %", 0...100) {
            reading.add(SensorInfo(key: SensorKeys.gpuRendererUsage, label: "GPU renderer usage", kind: .percent,
                                   source: "IOAccelerator PerformanceStatistics"), r)
        }
        if let t = best("Tiler Utilization %", 0...100) {
            reading.add(SensorInfo(key: SensorKeys.gpuTilerUsage, label: "GPU tiler usage", kind: .percent,
                                   source: "IOAccelerator PerformanceStatistics"), t)
        }
        let memory = valid.compactMap { number($0, "In use system memory") ?? number($0, "vramUsedBytes") }
            .filter { $0 >= 0 }
        if !memory.isEmpty {
            reading.add(SensorInfo(key: SensorKeys.gpuMemory, label: "GPU memory in use", kind: .bytes,
                                   source: "IOAccelerator PerformanceStatistics"), memory.reduce(0, +))
        }
        if let t = best("Temperature(C)", 1...150) {
            reading.add(SensorInfo(key: SensorKeys.gpu, label: "GPU temperature", kind: .temperature,
                                   source: "IOAccelerator PerformanceStatistics"), t)
        }
        if let f = best("Fan Speed(%)", 0...100) {
            reading.add(SensorInfo(key: SensorKeys.gpuFan, label: "GPU fan", kind: .percent,
                                   source: "IOAccelerator PerformanceStatistics"), f)
        }
        if let c = best("Core Clock(MHz)", 1...10_000) {
            reading.add(SensorInfo(key: SensorKeys.frequencyGPU, label: "GPU clock", kind: .frequency,
                                   source: "IOAccelerator PerformanceStatistics"), c)
        }
        if let c = best("Memory Clock(MHz)", 1...20_000) {
            reading.add(SensorInfo(key: SensorKeys.frequencyGPUMemory, label: "GPU memory clock", kind: .frequency,
                                   source: "IOAccelerator PerformanceStatistics"), c)
        }
        return reading
    }

    // MARK: Battery

    /// The raw capacity ratio shared by MacSensors and the battery-details fallback. Keep the Intel distinction:
    /// a MaxCapacity at most 100 is a percentage, not a full-charge capacity in mAh.
    static func batteryHealth(_ d: [String: Any]) -> Double? {
        func number(_ key: String) -> Double? {
            guard let n = d[key] as? NSNumber else { return nil }
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        let design = number("DesignCapacity")
        let rawMax = number("AppleRawMaxCapacity") ?? number("MaxCapacity").flatMap { $0 > 100 ? $0 : nil }
        guard let design, design > 0, let rawMax, rawMax > 0 else { return nil }
        return rawMax / design * 100
    }

    /// The battery group from AppleSmartBattery's properties: health = full-charge capacity (`AppleRawMaxCapacity`,
    /// or `MaxCapacity` when it is in mAh as on Intel Macs) ÷ `DesignCapacity`; `CycleCount`; `Voltage` (mV → V);
    /// `Amperage` (mA → A, negative while discharging; the registry stores it as an unsigned 64-bit pattern);
    /// `Temperature` (0.01 °C → °C, used for `battery` when the SMC has no battery sensor).
    static func battery(_ d: [String: Any]) -> SensorGroupReading {
        var reading = SensorGroupReading()
        func number(_ key: String) -> Double? {
            guard let n = d[key] as? NSNumber else { return nil }
            return n.doubleValue.isFinite ? n.doubleValue : nil
        }
        /// The registry keeps negative currents as 64-bit two's complement patterns: read the bits as signed.
        func signed(_ key: String) -> Double? {
            guard let n = d[key] as? NSNumber else { return nil }
            return Double(n.int64Value)
        }
        let source = "AppleSmartBattery"
        if let health = batteryHealth(d) {
            reading.add(SensorInfo(key: SensorKeys.batteryHealth, label: "Battery health", kind: .percent,
                                   source: "\(source) full-charge ÷ design capacity"), health)
        }
        if let cycles = number("CycleCount"), cycles >= 0 {
            reading.add(SensorInfo(key: SensorKeys.batteryCycles, label: "Battery cycle count", kind: .count,
                                   maximum: number("DesignCycleCount9C"), source: source), cycles)
        }
        if let mv = number("Voltage"), mv > 0, mv < 100_000 {
            reading.add(SensorInfo(key: SensorKeys.batteryVoltage, label: "Battery voltage", kind: .voltage,
                                   source: source), mv / 1000)
        }
        if let ma = signed("InstantAmperage") ?? signed("Amperage"), abs(ma) < 100_000 {
            reading.add(SensorInfo(key: SensorKeys.batteryCurrent, label: "Battery current", kind: .current,
                                   source: source), ma / 1000)
        }
        if let t = number("Temperature"), t > 0 {
            let celsius = t / 100
            if celsius > -20, celsius < 100 {
                reading.add(SensorInfo(key: SensorKeys.battery, label: "Battery temperature", kind: .temperature,
                                       source: source), celsius)
            }
        }
        return reading
    }
}
