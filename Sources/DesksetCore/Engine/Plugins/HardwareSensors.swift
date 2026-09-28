import Foundation

// Hardware sensors: temperatures, fans, power, clock frequencies, GPU load and battery details.
//
// The engine sees them through `HardwareSensorSource`: a catalog of stable keys (`SensorKeys`, e.g. `cpu`, `fan.1`,
// `power.system`) with a value each, plus the older per-kind requirements CoreTemp, SpeedFan and the Performance
// Monitor counters were written against, which default to catalog keys. The app's `SystemMonitor` is the source on
// a Mac (SMC, IOReport, IOKit; see Sources/Deskset/Sensors); the tests use fakes. Mac-vs-Windows differences:
// docs/compat/plugins.md ("Hardware sensors").

// MARK: - Catalog

/// What a sensor measures, and its unit.
public enum SensorKind: String, CaseIterable, Sendable {
    /// °C.
    case temperature
    /// A fan's speed in RPM.
    case fan
    /// Watts.
    case power
    /// MHz.
    case frequency
    /// 0…100.
    case percent
    /// A plain number (the battery's cycle count).
    case count
    /// Volts.
    case voltage
    /// Amperes; negative while the battery discharges.
    case current
    /// Bytes.
    case bytes

    /// The unit written after a reading ("" for counts).
    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .fan: return "RPM"
        case .power: return "W"
        case .frequency: return "MHz"
        case .percent: return "%"
        case .count: return ""
        case .voltage: return "V"
        case .current: return "A"
        case .bytes: return "B"
        }
    }

    /// The range a measure of this kind uses when the skin sets no MinValue / MaxValue and the sensor reports none:
    /// 0–100 for temperatures (°C) and percentages; nil for kinds without a natural range (they follow the values
    /// seen, like other plugin measures).
    public var defaultRange: ClosedRange<Double>? {
        switch self {
        case .temperature, .percent: return 0...100
        default: return nil
        }
    }
}

/// One sensor of the catalog.
public struct SensorInfo: Equatable, Sendable {
    /// The stable key skins use (`SensorKeys`), lower-case.
    public var key: String
    /// Plain words, e.g. "CPU performance cores".
    public var label: String
    public var kind: SensorKind
    /// The lowest and highest value the hardware reports for this sensor when it tells (a fan's minimum and maximum
    /// speed, a CPU cluster's lowest and highest clock); nil otherwise.
    public var minimum: Double?
    public var maximum: Double?
    /// Where the value comes from, for reports ("SMC Tp01 … (12 keys)", "IOReport Energy Model").
    public var source: String

    public init(key: String, label: String, kind: SensorKind, minimum: Double? = nil, maximum: Double? = nil,
                source: String = "") {
        self.key = key
        self.label = label
        self.kind = kind
        self.minimum = minimum
        self.maximum = maximum
        self.source = source
    }
}

/// Temperature unit of a skin option (`Scale=`, `SpeedFanScale=`): C (default), F or K.
public enum TemperatureScale: String, CaseIterable, Sendable {
    case celsius = "C", fahrenheit = "F", kelvin = "K"

    /// `C` / `F` / `K` in any case; anything else is Celsius.
    public init(option: String) {
        switch option.trimmingCharacters(in: .whitespaces).lowercased() {
        case "f", "fahrenheit": self = .fahrenheit
        case "k", "kelvin": self = .kelvin
        default: self = .celsius
        }
    }

    public func convert(_ celsius: Double) -> Double {
        switch self {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9 / 5 + 32
        case .kelvin: return celsius + 273.15
        }
    }

    public var unit: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        case .kelvin: return "K"
        }
    }
}

/// The catalog's keys. Numbered keys count from 1 (`cpu.core.1` is the first core, `fan.1` the first fan), like
/// `Processor=1` of the CPU measure.
public enum SensorKeys {
    // Temperatures (°C)
    /// The hottest valid CPU sensor.
    public static let cpu = "cpu"
    public static let cpuPerformance = "cpu.performance"
    public static let cpuEfficiency = "cpu.efficiency"
    public static let gpu = "gpu"
    /// The rest of the chip on Apple silicon; the chipset (PCH) on an Intel Mac.
    public static let soc = "soc"
    public static let battery = "battery"
    public static let ssd = "ssd"
    /// Core `n` (1-based). On Apple silicon: the hottest sensor of the core's cluster (macOS names no sensor per core).
    public static func cpuCore(_ n: Int) -> String { "cpu.core.\(n)" }

    // Fans (RPM)
    public enum FanValue: String, CaseIterable, Sendable {
        case actual = "", minimum = "min", maximum = "max", target = "target"
    }
    /// Fan `n` (1-based): its speed, or its minimum / maximum / target speed.
    public static func fan(_ n: Int, _ value: FanValue = .actual) -> String {
        value == .actual ? "fan.\(n)" : "fan.\(n).\(value.rawValue)"
    }

    // Power (W)
    public static let powerSystem = "power.system"
    public static let powerAdapter = "power.adapter"
    public static let powerCPU = "power.cpu"
    public static let powerGPU = "power.gpu"
    public static let powerANE = "power.ane"
    public static let powerDRAM = "power.dram"

    // Clock frequencies (MHz)
    /// The faster of the CPU clusters' average clocks.
    public static let frequencyCPU = "frequency.cpu"
    public static let frequencyPerformance = "frequency.cpu.performance"
    public static let frequencyEfficiency = "frequency.cpu.efficiency"
    public static let frequencyGPU = "frequency.gpu"
    public static let frequencyGPUMemory = "frequency.gpu.memory"
    public static func frequencyCore(_ n: Int) -> String { "frequency.cpu.\(n)" }

    // Voltages (V)
    /// The voltage the CPU's busiest cluster asked for, on average (CoreTemp's Vid).
    public static let voltageCPU = "voltage.cpu"

    // GPU
    public static let gpuUsage = "gpu.usage"
    public static let gpuRendererUsage = "gpu.usage.renderer"
    public static let gpuTilerUsage = "gpu.usage.tiler"
    /// Memory the GPU uses, in bytes (on Apple silicon: the part of the unified memory it has in use).
    public static let gpuMemory = "gpu.memory"
    /// A discrete GPU's own fan, percent.
    public static let gpuFan = "gpu.fan"

    // Battery
    /// Full-charge capacity as a percentage of the design capacity.
    public static let batteryHealth = "battery.health"
    public static let batteryCycles = "battery.cycles"
    public static let batteryVoltage = "battery.voltage"
    /// Negative while discharging.
    public static let batteryCurrent = "battery.current"

    /// Other spellings skins may use, and what they mean.
    public static let aliases: [String: String] = [
        "battery.temperature": battery, "cpu.temperature": cpu, "cpu.package": cpu, "cpu.max": cpu,
        "gpu.temperature": gpu, "soc.temperature": soc, "ssd.temperature": ssd, "cpu.p": cpuPerformance,
        "cpu.e": cpuEfficiency, "fan": "fan.1", "power": powerSystem, "frequency.cpu.p": frequencyPerformance,
        "frequency.cpu.e": frequencyEfficiency, "gpu.clock": frequencyGPU, "cpu.clock": frequencyCPU,
    ]

    /// Trimmed, lower-case, with aliases resolved.
    public static func canonical(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") { key = String(key.dropFirst().dropLast()) }
        return aliases[key] ?? key
    }

    /// The kind a key has by its name; nil for a name that is not a catalog key.
    public static func kind(of rawKey: String) -> SensorKind? {
        let key = canonical(rawKey)
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first else { return nil }
        func isNumber(_ s: String) -> Bool { Int(s).map { $0 >= 1 } ?? false }
        switch head {
        case "cpu":
            if parts.count == 1 { return .temperature }
            if parts.count == 2, parts[1] == "performance" || parts[1] == "efficiency" { return .temperature }
            if parts.count == 3, parts[1] == "core", isNumber(parts[2]) { return .temperature }
            return nil
        case "gpu":
            if parts.count == 1 { return .temperature }
            switch parts.dropFirst().joined(separator: ".") {
            case "usage", "usage.renderer", "usage.tiler", "fan": return .percent
            case "memory": return .bytes
            default: return nil
            }
        case "soc", "ssd": return parts.count == 1 ? .temperature : nil
        case "battery":
            if parts.count == 1 { return .temperature }
            switch parts.count == 2 ? parts[1] : "" {
            case "health": return .percent
            case "cycles": return .count
            case "voltage": return .voltage
            case "current": return .current
            default: return nil
            }
        case "fan":
            guard parts.count >= 2, isNumber(parts[1]) else { return nil }
            if parts.count == 2 { return .fan }
            return parts.count == 3 && ["min", "max", "target"].contains(parts[2]) ? .fan : nil
        case "power":
            return parts.count == 2 && ["system", "adapter", "cpu", "gpu", "ane", "dram"].contains(parts[1])
                ? .power : nil
        case "frequency":
            guard parts.count >= 2 else { return nil }
            if parts[1] == "gpu" { return parts.count == 2 || (parts.count == 3 && parts[2] == "memory") ? .frequency : nil }
            guard parts[1] == "cpu" else { return nil }
            if parts.count == 2 { return .frequency }
            return parts.count == 3 && (["performance", "efficiency"].contains(parts[2]) || isNumber(parts[2]))
                ? .frequency : nil
        case "voltage":
            return key == voltageCPU ? .voltage : nil
        default:
            return nil
        }
    }

    /// Keys a Mac may have, in catalog order, with plain labels (the editor's menu, `--system-report`'s order).
    /// Numbered keys appear once, for core / fan 1.
    public static let common: [(key: String, label: String)] = [
        (cpu, "CPU temperature (hottest sensor)"), (cpuPerformance, "CPU performance cores temperature"),
        (cpuEfficiency, "CPU efficiency cores temperature"), (cpuCore(1), "CPU core 1 temperature"),
        (gpu, "GPU temperature"), (soc, "Chip or chipset temperature"), (battery, "Battery temperature"),
        (ssd, "SSD temperature"),
        (fan(1), "Fan 1 speed"), (fan(1, .minimum), "Fan 1 minimum speed"), (fan(1, .maximum), "Fan 1 maximum speed"),
        (fan(1, .target), "Fan 1 target speed"),
        (powerSystem, "Power: whole Mac"), (powerAdapter, "Power: from the adapter"), (powerCPU, "Power: CPU"),
        (powerGPU, "Power: GPU"), (powerANE, "Power: Neural Engine"), (powerDRAM, "Power: memory"),
        (frequencyCPU, "CPU clock (fastest cluster)"), (frequencyPerformance, "CPU performance cores clock"),
        (frequencyEfficiency, "CPU efficiency cores clock"), (frequencyCore(1), "CPU core 1 clock"),
        (frequencyGPU, "GPU clock"), (frequencyGPUMemory, "GPU memory clock"),
        (voltageCPU, "CPU voltage"),
        (gpuUsage, "GPU usage"), (gpuRendererUsage, "GPU renderer usage"), (gpuTilerUsage, "GPU tiler usage"),
        (gpuMemory, "GPU memory in use"), (gpuFan, "GPU fan"),
        (batteryHealth, "Battery health"), (batteryCycles, "Battery cycle count"),
        (batteryVoltage, "Battery voltage"), (batteryCurrent, "Battery current"),
    ]

    /// SpeedFan's temperatures in `SpeedFanNumber` order (0-based); the cores follow (`cpu.core.1` at index 7…).
    /// A sensor this Mac lacks keeps its place, reading 0, so an index means the same on every Mac.
    public static let speedFanTemperatures = [cpu, gpu, soc, battery, ssd, cpuPerformance, cpuEfficiency]
    /// SpeedFan's voltages in `SpeedFanNumber` order.
    public static let speedFanVoltages = [voltageCPU, batteryVoltage]

    /// A reading with its unit, as MacSensors shows it: "52 °C", "2317 RPM", "12.4 W", "3504 MHz", "24 %", "223",
    /// "11.89 V", "1.2 GB". Temperatures are converted to `scale` first.
    public static func text(_ value: Double, kind: SensorKind, scale: TemperatureScale = .celsius) -> String {
        guard value.isFinite else { return "" }
        func number(_ v: Double, _ decimals: Int) -> String {
            var s = String(format: "%.\(decimals)f", v)
            if s.hasPrefix("-"), Double(s) == 0 { s.removeFirst() }   // no "-0"
            return s
        }
        switch kind {
        case .temperature: return number(scale.convert(value), 0) + " " + scale.unit
        case .fan, .frequency: return number(value, 0) + " " + kind.unit
        case .percent: return number(value, 0) + " %"
        case .count: return number(value, 0)
        case .power: return number(value, value.magnitude >= 100 ? 0 : 1) + " W"
        case .voltage: return number(value, 2) + " V"
        case .current: return number(value, 2) + " A"
        case .bytes:
            let units = ["B", "KB", "MB", "GB", "TB"]
            var v = value, i = 0
            while v.magnitude >= 1024, i < units.count - 1 {
                v /= 1024
                i += 1
            }
            return number(v, i == 0 ? 0 : 1) + " " + units[i]
        }
    }
}

// MARK: - Source

/// Hardware sensors for plugins (CoreTemp, SpeedFan, MSIAfterburner, MacSensors, the Performance Monitor counters of
/// UsageMonitor / PerfMon). The app's `SystemMonitor` implements it; plugins find it with `HardwareSensors.source(for:)`.
///
/// A source answers from readings it takes in the background: every call must return at once and may come from any
/// thread (skins may run on threads of their own, docs/skin-threading.md). A sensor asked for the first time usually
/// has no value yet (`sensorPending`): the source starts reading it, and a later update sees it.
///
/// Every requirement has a default, so a source implements only what it can read: the catalog ones default to
/// "nothing", the per-kind ones to catalog keys (e.g. `cpuPackageTemperature()` = `cpu`, `fanSpeeds()` =
/// `fan.1`, `fan.2`…).
public protocol HardwareSensorSource: AnyObject {
    /// The sensors this Mac has, in catalog order, as far as the source knows them (it learns a group of sensors when
    /// something first asks for one of them; `discoverSensors` asks for all).
    func sensorList() -> [SensorInfo]
    /// The catalog entry of `key` (canonical), when known.
    func sensorInfo(_ key: String) -> SensorInfo?
    /// The reading of a catalog key (canonical, see `SensorKeys.canonical`) in its kind's unit; nil when this Mac has no
    /// such sensor, or has no reading of it yet.
    func sensorValue(_ key: String) -> Double?
    /// True while `key` has no reading only because the source has not read its group yet: its absence says nothing.
    func sensorPending(_ key: String) -> Bool
    /// Reads every sensor this Mac has (in the background) and calls `done` with the list, on any thread.
    func discoverSensors(_ done: @escaping ([SensorInfo]) -> Void)

    /// °C per CPU core (index 0 = first core).
    func cpuCoreTemperatures() -> [Double]?
    /// °C of the hottest core / the CPU package.
    func cpuPackageTemperature() -> Double?
    /// °C, maximum junction temperature.
    func cpuTjMax() -> Double?
    /// MHz per core.
    func cpuCoreFrequencies() -> [Double]?
    /// Watts drawn by the CPU.
    func cpuPower() -> Double?
    /// Thermal design power in watts.
    func cpuTDP() -> Double?
    /// Core voltage (VID) in volts.
    func cpuVoltage() -> Double?
    /// All temperature sensors in °C (SpeedFan `SpeedFanNumber` indexes this list).
    func temperatures() -> [Double]
    /// All fans in RPM.
    func fanSpeeds() -> [Double]
    /// All voltage sensors in volts.
    func voltages() -> [Double]
    /// GPU utilisation 0…100.
    func gpuUtilization() -> Double?
    /// macOS's thermal state 0–3 (MacSensors `Sensor=thermal`) when this source gives it; nil: the Mac's own
    /// (`MacSensorsMeasure.thermalState`).
    func thermalState() -> Int?
}

extension HardwareSensorSource {
    public func sensorList() -> [SensorInfo] { [] }
    public func sensorInfo(_ key: String) -> SensorInfo? { sensorList().first { $0.key == key } }
    public func sensorValue(_ key: String) -> Double? { nil }
    public func sensorPending(_ key: String) -> Bool { false }
    public func discoverSensors(_ done: @escaping ([SensorInfo]) -> Void) { done(sensorList()) }

    public func cpuCoreTemperatures() -> [Double]? { numbered(SensorKeys.cpuCore) }
    public func cpuPackageTemperature() -> Double? {
        sensorValue(SensorKeys.cpu) ?? cpuCoreTemperatures()?.max()
    }
    public func cpuTjMax() -> Double? { nil }
    public func cpuCoreFrequencies() -> [Double]? { numbered(SensorKeys.frequencyCore) }
    public func cpuPower() -> Double? { sensorValue(SensorKeys.powerCPU) }
    public func cpuTDP() -> Double? { nil }
    public func cpuVoltage() -> Double? { sensorValue(SensorKeys.voltageCPU) }
    /// `SensorKeys.speedFanTemperatures`, then the cores; without any of those, the cores alone.
    public func temperatures() -> [Double] {
        let fixed = SensorKeys.speedFanTemperatures.map { sensorValue($0) }
        let cores = cpuCoreTemperatures() ?? []
        guard fixed.contains(where: { $0 != nil }) else { return cores }
        return fixed.map { $0 ?? 0 } + cores
    }
    public func fanSpeeds() -> [Double] { numbered { SensorKeys.fan($0) } ?? [] }
    public func voltages() -> [Double] {
        let fixed = SensorKeys.speedFanVoltages.map { sensorValue($0) }
        return fixed.contains { $0 != nil } ? fixed.map { $0 ?? 0 } : []
    }
    public func gpuUtilization() -> Double? { sensorValue(SensorKeys.gpuUsage) }
    public func thermalState() -> Int? { nil }

    /// The values of `key(1)`, `key(2)`… up to the first one without a value; nil when even the first has none.
    func numbered(_ key: (Int) -> String) -> [Double]? {
        var list: [Double] = []
        while list.count < 1024, let v = sensorValue(key(list.count + 1)) { list.append(v) }
        return list.isEmpty ? nil : list
    }

    /// Core `index` (0-based) temperature: the catalog's `cpu.core.N`, else the per-core list.
    func coreTemperature(_ index: Int) -> Double? {
        if let v = sensorValue(SensorKeys.cpuCore(index + 1)) { return v }
        guard let list = cpuCoreTemperatures(), index < list.count else { return nil }
        return list[index]
    }

    /// Core `index` (0-based) clock in MHz, or the fastest when nil: the catalog, else the per-core list.
    func coreFrequency(_ index: Int?) -> Double? {
        if let index {
            if let v = sensorValue(SensorKeys.frequencyCore(index + 1)) { return v }
            guard let list = cpuCoreFrequencies(), index < list.count else { return nil }
            return list[index]
        }
        return sensorValue(SensorKeys.frequencyCPU) ?? cpuCoreFrequencies()?.max()
    }
}

/// Where plugins look for hardware sensors: `skin.system` when it conforms to `HardwareSensorSource`, else `source`.
public enum HardwareSensors {
    /// A source for skins whose system data source is not one (tests). Main thread only.
    public static var source: HardwareSensorSource?

    static func source(for skin: Skin) -> HardwareSensorSource? {
        (skin.system as? HardwareSensorSource) ?? source
    }
}
