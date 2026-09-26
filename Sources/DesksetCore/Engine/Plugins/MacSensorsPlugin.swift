import Foundation

// Two plugins over the hardware sensor catalog (HardwareSensors.swift):
// - MacSensors, Deskset's own plugin for new skins (no Rainmeter counterpart);
// - MSIAfterburner, a stand-in for the third-party Windows plugin of that name, which reads MSI Afterburner's shared
//   memory. The option and the data source names public skin files use come from those files
//   (`DataSource=GPU temperature`, `Fan speed`, `Core clock`, `Memory clock`, `Memory usage`); the other data source
//   names are the monitoring names MSI Afterburner itself lists in its settings (`GPU usage`, `Fan tachometer`,
//   `CPU1 temperature`, `RAM usage`, `Framerate`…), as public guides show them. Nothing was taken from the plugin's
//   code.
// Differences from Windows: docs/compat/plugins.md.

// MARK: - MacSensors

/// `Plugin=MacSensors`: one hardware sensor by its catalog key.
/// - `Sensor=` a catalog key (`SensorKeys`: `cpu`, `cpu.core.3`, `gpu`, `fan.1`, `fan.1.max`, `power.system`,
///   `frequency.cpu.performance`, `gpu.usage`, `battery.health`…; case-insensitive, aliases accepted). Default `cpu`.
/// - `Scale=C` (default) / `F` / `K` for temperatures.
/// - Number: the reading in the kind's unit (°C / °F / K, RPM, W, MHz, %, V, A, bytes, a count); 0 while there is no
///   reading. String: the reading with its unit ("52 °C", "2317 RPM", "12.4 W"), "" while there is none.
/// - Range when MinValue / MaxValue are not set: temperatures 0–100 °C (in the scale's unit), percentages 0–100, fans and
///   clocks the lowest / highest value the hardware reports (a fan's minimum and maximum speed); other kinds follow the
///   values seen, like other plugin measures.
/// - `!CommandMeasure <measure> "List"` logs every sensor this Mac has, with its key, label and reading.
public final class MacSensorsMeasure: Measure, PluginLifecycle {
    private var key = SensorKeys.cpu
    private var kind: SensorKind? = .temperature
    private var scale = TemperatureScale.celsius
    private var info: SensorInfo?
    private var reported: Set<String> = []
    private var closed = false
    private var noReading = true

    /// The canonical key being read (tests).
    var sensorKey: String { key }

    public func skinWillClose() {
        closed = true
    }

    override var tracksValueRange: Bool { fixedRange == nil }

    /// Without a reading the string is empty: a String meter showing it keeps one line of height, as it would with
    /// the value (the sensor may simply not have been read yet).
    public override var valueUnavailable: Bool { noReading }

    /// The kind's own range, or the sensor's minimum / maximum when it reports both.
    private var fixedRange: ClosedRange<Double>? {
        if let info, let lo = info.minimum, let hi = info.maximum, hi > lo,
           info.kind == .fan || info.kind == .frequency {
            return lo...hi
        }
        guard let r = kind?.defaultRange else { return nil }
        return kind == .temperature ? scale.convert(r.lowerBound)...scale.convert(r.upperBound) : r
    }

    public override var automaticMinValue: Double { fixedRange?.lowerBound ?? 0 }
    public override var automaticMaxValue: Double { fixedRange?.upperBound ?? 1 }

    public override func readMeasureOptions() {
        let raw = string("Sensor", SensorKeys.cpu)
        key = SensorKeys.canonical(raw.isEmpty ? SensorKeys.cpu : raw)
        kind = SensorKeys.kind(of: key)
        if kind == nil {
            report("key:\(key)", "MacSensors [\(name)]: \"\(raw)\" is not a sensor name (e.g. cpu, gpu, fan.1, "
                   + "power.system); !CommandMeasure \(name) List logs this Mac's sensors")
        }
        scale = TemperatureScale(option: string("Scale", "C"))
        info = nil
    }

    public override func computeValue() -> Double {
        rawString = ""
        noReading = true
        guard let kind else { return 0 }
        guard let sensors = HardwareSensors.source(for: skin) else {
            report("none", "MacSensors [\(name)]: hardware sensors are not available here; the value is 0")
            return 0
        }
        if info == nil { info = sensors.sensorInfo(key) }
        guard let v = sensors.sensorValue(key), v.isFinite else {
            if !sensors.sensorPending(key) {
                report("missing", "MacSensors [\(name)]: this Mac has no sensor \"\(key)\"; the value is 0 "
                       + "(!CommandMeasure \(name) List logs the sensors it has)")
            }
            return 0
        }
        noReading = false
        rawString = SensorKeys.text(v, kind: info?.kind ?? kind, scale: scale)
        return (info?.kind ?? kind) == .temperature ? scale.convert(v) : v
    }

    /// `List`: every sensor, logged once the source has read them all.
    public override func execute(command: String) {
        let words = command.split(separator: " ").map { $0.lowercased() }
        guard words.first == "list" else {
            skin.log("MacSensors [\(name)]: unknown command \"\(command)\" (the command is List)", level: .warning)
            return
        }
        guard let sensors = HardwareSensors.source(for: skin) else {
            skin.log("MacSensors [\(name)]: hardware sensors are not available here", level: .notice)
            return
        }
        let hop = skin.hop()
        let scale = self.scale
        sensors.discoverSensors { [weak self] list in
            let lines = MacSensorsMeasure.listLines(list, values: { sensors.sensorValue($0) }, scale: scale)
            hop.post {
                guard let self, !self.closed else { return }
                for line in lines { self.skin.log("MacSensors [\(self.name)]: \(line)", level: .notice) }
            }
        }
    }

    /// One line per sensor: "cpu — CPU temperature (hottest sensor): 52 °C".
    static func listLines(_ list: [SensorInfo], values: (String) -> Double?, scale: TemperatureScale) -> [String] {
        guard !list.isEmpty else { return ["this Mac reports no hardware sensors"] }
        return ["\(list.count) sensors:"] + list.map { info in
            let reading = values(info.key).map { SensorKeys.text($0, kind: info.kind, scale: scale) } ?? "no reading yet"
            return "\(info.key) — \(info.label): \(reading)"
        }
    }

    private func report(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        skin.log(message, level: .notice)
    }
}

// MARK: - MSIAfterburner

/// `Plugin=MSIAfterburner` with `DataSource=<the name MSI Afterburner shows>`. On the Mac:
/// - `GPU temperature` = `gpu` (°C); `GPU usage` = `gpu.usage`; `Core clock` = `frequency.gpu` (MHz);
///   `Memory clock` = `frequency.gpu.memory` (MHz; 0 on Apple silicon, whose GPU uses the unified memory);
///   `Memory usage` = `gpu.memory` in MB (on Apple silicon the unified memory the GPU has in use);
///   `Fan speed` = a discrete GPU's fan (`gpu.fan`, %), else the fastest Mac fan as a percentage of its maximum speed;
///   `Fan tachometer` = the fastest fan in RPM; `GPU power` / `CPU power` = `power.gpu` / `power.cpu` (W);
///   `CPU temperature` = `cpu`, `CPUn temperature` = `cpu.core.n`; `CPU usage` / `CPUn usage` = the CPU measure's
///   values; `CPU clock` / `CPUn clock` = `frequency.cpu` / `frequency.cpu.n`; `RAM usage` = memory used in MB.
/// - `GPU1 …` means the same as `GPU …` (a Mac has one GPU for these values); `GPU2 …` and other names are 0, logged
///   once. Names are matched case-insensitively.
public final class MSIAfterburnerMeasure: Measure {
    enum Source: Equatable {
        case sensor(String)
        case megabytes(String)
        case fanPercent, fanRPM
        case cpuUsage(Int)
        case ramUsage
        case unsupported
    }

    private var source = Source.unsupported
    private var reported: Set<String> = []

    override var tracksValueRange: Bool { true }

    /// The data source a `DataSource=` name reads.
    static func source(for raw: String) -> Source {
        var name = raw.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
        // "GPU1 temperature" → "gpu temperature"; other GPUs do not exist here.
        if let match = name.range(of: #"^gpu(\d+) "#, options: .regularExpression) {
            let n = Int(name[match].dropFirst(3).dropLast()) ?? 0
            guard n == 1 else { return .unsupported }
            name = "gpu " + name[match.upperBound...]
        }
        // Names that start with "gpu " may also be written without it ("GPU core clock" / "Core clock").
        let bare = name.hasPrefix("gpu ") ? String(name.dropFirst(4)) : name
        switch bare {
        case "temperature": return .sensor(SensorKeys.gpu)
        case "usage": return .sensor(SensorKeys.gpuUsage)
        case "core clock": return .sensor(SensorKeys.frequencyGPU)
        case "memory clock": return .sensor(SensorKeys.frequencyGPUMemory)
        case "memory usage": return .megabytes(SensorKeys.gpuMemory)
        case "fan speed": return .fanPercent
        case "fan tachometer": return .fanRPM
        case "power" where name.hasPrefix("gpu "): return .sensor(SensorKeys.powerGPU)
        default: break
        }
        switch name {
        case "cpu temperature": return .sensor(SensorKeys.cpu)
        case "cpu usage": return .cpuUsage(0)
        case "cpu clock": return .sensor(SensorKeys.frequencyCPU)
        case "cpu power": return .sensor(SensorKeys.powerCPU)
        case "ram usage": return .ramUsage
        default: break
        }
        if name.range(of: #"^cpu(\d+) (temperature|usage|clock)$"#, options: .regularExpression) != nil {
            let parts = name.dropFirst(3).split(separator: " ")
            guard let n = Int(parts[0]), n >= 1, n <= 4096 else { return .unsupported }
            switch parts[1] {
            case "temperature": return .sensor(SensorKeys.cpuCore(n))
            case "usage": return .cpuUsage(n)
            default: return .sensor(SensorKeys.frequencyCore(n))
            }
        }
        return .unsupported
    }

    public override func readMeasureOptions() {
        let raw = string("DataSource")
        source = MSIAfterburnerMeasure.source(for: raw)
        if source == .unsupported {
            report("source:\(raw.lowercased())", "MSIAfterburner [\(name)]: DataSource=\(raw) has no Mac equivalent; "
                   + "the value is 0")
        }
    }

    public override func computeValue() -> Double {
        let sensors = HardwareSensors.source(for: skin)
        func sensor(_ key: String) -> Double {
            guard let sensors else {
                report("none", "MSIAfterburner [\(name)]: hardware sensors are not available here; the value is 0")
                return 0
            }
            if let v = sensors.sensorValue(key) { return v }
            if !sensors.sensorPending(key) {
                report("missing", "MSIAfterburner [\(name)]: this Mac does not report \(key); the value is 0")
            }
            return 0
        }
        switch source {
        case .sensor(let key):
            return sensor(key)
        case .megabytes(let key):
            return sensor(key) / 1_048_576
        case .fanPercent:
            if let gpuFan = sensors?.sensorValue(SensorKeys.gpuFan) { return gpuFan }
            return MSIAfterburnerMeasure.fans(sensors).map { $0.max > 0 ? $0.actual / $0.max * 100 : 0 }.max()
                ?? sensor(SensorKeys.fan(1))
        case .fanRPM:
            return MSIAfterburnerMeasure.fans(sensors).map(\.actual).max() ?? sensor(SensorKeys.fan(1))
        case .cpuUsage(let n):
            guard n <= skin.system.processorCount else { return 0 }
            return skin.system.cpuUsage(processor: n)
        case .ramUsage:
            return skin.system.memoryStatus().physicalUsed / 1_048_576
        case .unsupported:
            return 0
        }
    }

    /// Every fan's speed and maximum (RPM).
    private static func fans(_ sensors: HardwareSensorSource?) -> [(actual: Double, max: Double)] {
        guard let sensors else { return [] }
        var list: [(Double, Double)] = []
        while list.count < 64, let actual = sensors.sensorValue(SensorKeys.fan(list.count + 1)) {
            let n = list.count + 1
            let max = sensors.sensorValue(SensorKeys.fan(n, .maximum)) ?? sensors.sensorInfo(SensorKeys.fan(n))?.maximum
            list.append((actual, max ?? 0))
        }
        return list
    }

    private func report(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        skin.log(message, level: .notice)
    }
}
