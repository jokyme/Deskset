import Darwin
import Foundation

// Clean-room implementations from the public manual only:
//   https://docs.rainmeter.net/manual/plugins/coretemp/
//   https://docs.rainmeter.net/manual/plugins/speedfan/
//   https://docs.rainmeter.net/manual/plugins/resmon/
//   https://docs.rainmeter.net/manual/plugins/windowmessage/
//   https://docs.rainmeter.net/manual/measures/ ("Percentage": plugin measures such as SpeedFan track their range)

// MARK: - CoreTemp

/// `Plugin=CoreTemp`: on Windows it reads the Core Temp application. On the Mac:
/// - `Load` (per core, `CoreTempIndex` 0-based) comes from the CPU data the CPU measure uses (`SystemDataSource`);
/// - `CpuName` is the processor brand string (e.g. "Apple M2 Pro");
/// - the rest comes from the hardware sensors (`HardwareSensorSource`, docs/compat/plugins.md): `MaxTemperature` (the
///   default) = the catalog's `cpu`, `Temperature` = `cpu.core.N` (on Apple silicon the core's cluster), `TjMax` =
///   the source's nominal value, `Power` = `power.cpu`, `Vid` = `voltage.cpu`, `CpuSpeed` = `frequency.cpu`,
///   `CoreSpeed` = `frequency.cpu.N`; `Tdp` has no Mac source (0);
/// - `CpuSpeed` / `CoreSpeed` without a sensor reading are the rated frequency when the system reports one (Intel
///   Macs), else 0;
/// - `BusSpeed`, `BusMultiplier`, `CoreBusMultiplier` have no meaning on Apple Silicon: 0 (with a sensor source that
///   reports frequencies, BusSpeed is 100 MHz and the multipliers are frequency / 100, like a PC's reference clock).
/// A value the Mac does not report is 0, logged once (not while the source is still reading that sensor for the first
/// time). Temperatures are Celsius (Core Temp's Fahrenheit setting has no counterpart). As the manual says, MinValue /
/// MaxValue must be set for percentages: like every plugin measure the range otherwise tracks the observed values.
public final class CoreTempMeasure: Measure {
    /// Reads the Mac's sensors, and its CPU use and frequency (virtual time: noted, see `Measure.liveInputs`).
    public override var liveInputs: [BackgroundWorkKind] { [.sensors, .system] }

    enum Kind: String, CaseIterable {
        case cpuName = "cpuname", cpuSpeed = "cpuspeed", maxTemperature = "maxtemperature", busSpeed = "busspeed"
        case busMultiplier = "busmultiplier", vid = "vid", tdp = "tdp", power = "power", temperature = "temperature"
        case tjMax = "tjmax", coreBusMultiplier = "corebusmultiplier", coreSpeed = "corespeed", load = "load"
    }

    private var kind = Kind.maxTemperature
    private var index = 0
    private var reported: Set<String> = []

    override var tracksValueRange: Bool { true }

    public override func readMeasureOptions() {
        let raw = string("CoreTempType", "MaxTemperature").trimmingCharacters(in: .whitespaces)
        if let k = Kind(rawValue: raw.lowercased()) {
            kind = k
        } else {
            kind = .maxTemperature
            report("type:\(raw.lowercased())", "CoreTemp [\(name)]: unknown CoreTempType=\(raw); using MaxTemperature")
        }
        index = min(max(int("CoreTempIndex", 0), 0), 4095)
    }

    public override func computeValue() -> Double {
        rawString = nil
        let sensors = HardwareSensors.source(for: sectionContext.system)
        /// 0, and a note once: no sensors at all, or the Mac does not report this value (not while it is pending).
        func missing(_ what: String, _ key: String) -> Double {
            guard let sensors else {
                report("sensor", "CoreTemp [\(name)]: \(what) needs hardware sensors, which are not available here; "
                       + "the value is 0")
                return 0
            }
            if !sensors.sensorPending(key) {
                report("missing:\(what)", "CoreTemp [\(name)]: this Mac reports no \(what); the value is 0")
            }
            return 0
        }
        switch kind {
        case .cpuName:
            rawString = CoreTempMeasure.cpuBrand
            return 0
        case .load:
            guard index < sectionContext.system.processorCount else { return 0 }
            return sectionContext.system.cpuUsage(processor: index + 1)
        case .cpuSpeed:
            return coreFrequency(sensors, core: nil)
        case .coreSpeed:
            return coreFrequency(sensors, core: index)
        case .maxTemperature:
            return sensors?.cpuPackageTemperature() ?? missing("MaxTemperature", SensorKeys.cpu)
        case .temperature:
            return sensors?.coreTemperature(index) ?? missing("Temperature", SensorKeys.cpuCore(index + 1))
        case .tjMax:
            return sensors?.cpuTjMax() ?? missing("TjMax", SensorKeys.cpu)
        case .vid:
            return sensors?.cpuVoltage() ?? missing("Vid", SensorKeys.voltageCPU)
        case .tdp:
            return sensors?.cpuTDP() ?? missing("Tdp", "tdp")
        case .power:
            return sensors?.cpuPower() ?? missing("Power", SensorKeys.powerCPU)
        case .busSpeed:
            return sensors?.coreFrequency(nil) != nil ? 100 : 0
        case .busMultiplier:
            let f = coreFrequency(sensors, core: nil)
            return f > 0 && sensors?.coreFrequency(nil) != nil ? f / 100 : 0
        case .coreBusMultiplier:
            let f = coreFrequency(sensors, core: index)
            return f > 0 && sensors?.coreFrequency(index) != nil ? f / 100 : 0
        }
    }

    /// MHz: the sensor source's value for the core (the fastest cluster for the CPU), else the rated frequency.
    private func coreFrequency(_ sensors: HardwareSensorSource?, core: Int?) -> Double {
        if let f = sensors?.coreFrequency(core) { return f }
        return (sectionContext.system.cpuFrequency() ?? 0) / 1_000_000
    }

    /// `machdep.cpu.brand_string` (read once).
    static let cpuBrand: String = sysctlString("machdep.cpu.brand_string") ?? "Unknown CPU"

    private func report(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        sectionContext.log(message, level: .notice)
    }
}

func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    let s = String(cString: buffer).trimmingCharacters(in: .whitespaces)
    return s.isEmpty ? nil : s
}

func sysctlInt(_ name: String) -> Int? {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
        var small: Int32 = 0
        var smallSize = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &small, &smallSize, nil, 0) == 0 else { return nil }
        return Int(small)
    }
    return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
}

// MARK: - SpeedFan

/// `Plugin=SpeedFanPlugin`: on Windows it reads the SpeedFan application. On the Mac it reads the same kinds of values
/// from a `HardwareSensorSource` (`SpeedFanType` Temperature / Fan / Voltage, `SpeedFanNumber` indexes the source's
/// list, `SpeedFanScale` C / F / K for temperatures). The lists have a fixed order on every Mac
/// (`SensorKeys.speedFanTemperatures` then the cores; fans 1, 2…; `SensorKeys.speedFanVoltages`), a sensor the Mac
/// lacks reading 0 in its place. Without a source, or past the end of a list, the value is 0 (logged once).
/// Like every plugin measure, the range tracks the observed values unless MinValue / MaxValue are set.
public final class SpeedFanMeasure: Measure {
    /// Reads the Mac's sensors (virtual time: noted, see `Measure.liveInputs`).
    public override var liveInputs: [BackgroundWorkKind] { [.sensors] }

    private var sensorType = "temperature"
    private var number = 0
    private var scale = TemperatureScale.celsius
    private var reported: Set<String> = []

    override var tracksValueRange: Bool { true }

    public override func readMeasureOptions() {
        sensorType = string("SpeedFanType", "Temperature").trimmingCharacters(in: .whitespaces).lowercased()
        number = min(max(int("SpeedFanNumber", 0), 0), 4095)
        scale = TemperatureScale(option: string("SpeedFanScale", "C"))
    }

    public override func computeValue() -> Double {
        guard let sensors = HardwareSensors.source(for: sectionContext.system) else {
            report("none", "SpeedFan [\(name)]: temperatures, fans and voltages need hardware sensors, which are not "
                   + "available here; the value is 0")
            return 0
        }
        let list: [Double]
        let first: String
        switch sensorType {
        case "fan":
            list = sensors.fanSpeeds()
            first = SensorKeys.fan(1)
        case "voltage":
            list = sensors.voltages()
            first = SensorKeys.speedFanVoltages[0]
        default:
            list = sensors.temperatures()
            first = SensorKeys.cpu
        }
        guard number < list.count else {
            if !sensors.sensorPending(first) {
                report("index", "SpeedFan [\(name)]: this Mac has no \(sensorType) number \(number) (it has "
                       + "\(list.count)); the value is 0")
            }
            return 0
        }
        let v = list[number]
        guard sensorType != "fan" && sensorType != "voltage" else { return v }
        return scale.convert(v)
    }

    private func report(_ key: String, _ message: String) {
        guard reported.insert(key).inserted else { return }
        sectionContext.log(message, level: .notice)
    }
}

// MARK: - ResMon

/// `Plugin=ResMon`: Windows GDI / USER objects, handles and windows. macOS has no GDI or USER objects, so:
/// - `ResCountType=Handle`: open file descriptors — of `ProcessName` (all processes with that name, `.exe` dropped)
///   when it is given and readable, otherwise of the whole system (`kern.num_files`);
/// - `GDI` (default), `USER`, `Window`: 0.
/// `ProcessName=Rainmeter.exe` means this app. The process ids for a name are looked up on a background queue (finding
/// them means reading the name of every process, ~10 ms) and reused for `pidRefreshInterval` seconds; counting the
/// descriptors of known ids at each update is cheap. A lookup that ends after the skin was unloaded is dropped.
public final class ResMonMeasure: Measure, PluginLifecycle {
    private var countType = "gdi"
    private var processName = ""
    private var pids: (name: String, list: [pid_t], time: TimeInterval)?
    private var lookingUp: String?
    private var closed = false

    /// The process ids last looked up for `ProcessName` (tests).
    var knownProcessIDs: [pid_t]? { pids?.list }

    public func skinWillClose() {
        closed = true
        lookingUp = nil
    }

    static var pidRefreshInterval: TimeInterval = 10

    override var tracksValueRange: Bool { true }

    public override func readMeasureOptions() {
        countType = string("ResCountType", "GDI").trimmingCharacters(in: .whitespaces).lowercased()
        var n = string("ProcessName").trimmingCharacters(in: .whitespaces)
        if n.hasPrefix("\""), n.hasSuffix("\""), n.count >= 2 { n = String(n.dropFirst().dropLast()) }
        if n.lowercased().hasSuffix(".exe") { n = String(n.dropLast(4)) }
        processName = n
    }

    public override func computeValue() -> Double {
        guard countType == "handle" else { return 0 }
        if processName.isEmpty { return Double(sysctlInt("kern.num_files") ?? 0) }
        let wanted = ProcessNames.normalized(processName)
        if wanted == "rainmeter" || wanted == ProcessNames.normalized(ProcessInfo.processInfo.processName) {
            return Double(ResMonMeasure.fileDescriptorCount(pids: [getpid()]))
        }
        let now = sectionContext.clock()
        let current = pids.flatMap { $0.name == processName ? $0 : nil }
        let stale = current.map { now - $0.time > ResMonMeasure.pidRefreshInterval } ?? true
        if !closed, lookingUp != processName, stale {
            let name = processName
            lookingUp = name
            // Live process state: no fake (the counts it leads to are read live anyway).
            let job = BackgroundJob(.resMon, subject: name, on: PluginIO.queue, fixture: false) {
                ProcessNames.pids(named: name)
            }
            sectionContext.startBackground(job) { [weak self] list in
                guard let self, !self.closed, self.lookingUp == name else { return }
                self.lookingUp = nil
                self.pids = (name, list, self.sectionContext.clock())
            }
        }
        return Double(ResMonMeasure.fileDescriptorCount(pids: current?.list ?? []))
    }

    static func fileDescriptorCount(processName: String) -> Int {
        fileDescriptorCount(pids: ProcessNames.pids(named: processName))
    }

    /// Open file descriptors of `pids` (processes that ended or cannot be inspected count 0).
    static func fileDescriptorCount(pids: [pid_t]) -> Int {
        var total = 0
        for pid in pids {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            if bytes > 0 { total += Int(bytes) / MemoryLayout<proc_fdinfo>.size }
        }
        return total
    }
}

// MARK: - WindowMessage

/// `Plugin=WindowMessagePlugin`: sends Windows messages (`SendMessage`) to a window found by `WindowName` /
/// `WindowClass` and returns the result or the window title. macOS has no window messages (and reading other apps'
/// window titles needs the Screen Recording permission), so the measure is 0 with an empty string, and
/// `!CommandMeasure … "SendMessage …"` is ignored. Both are logged once.
public final class WindowMessageMeasure: Measure {
    private var reported = false

    public override func readMeasureOptions() {
        if !reported {
            reported = true
            let target = string("WindowClass").isEmpty ? string("WindowName") : string("WindowClass")
            sectionContext.log("WindowMessage [\(name)]: Windows window messages do not exist on macOS"
                     + (target.isEmpty ? "" : " (window \"\(target)\")") + "; the value is 0", level: .notice)
        }
    }

    public override func computeValue() -> Double {
        rawString = ""
        return 0
    }

    public override func execute(command: String) {
        sectionContext.logOnce("WindowMessage [\(name)]: \"\(command)\" ignored (no window messages on macOS)", level: .notice)
    }
}

// MARK: - VirtualDesktops

/// `Plugin=VirtualDesktops` (a plugin for the Dexpot / VirtuaWin desktop managers). macOS Spaces have no public API,
/// so it reports a single desktop: `VDMeasureType=VDMActive` 0 (no manager running), `DesktopCount` /
/// `DesktopCountX` / `DesktopCountY` 1, `CurrentDesktop` 1, `DesktopName` "Desktop 1", everything else 0 / "".
/// Commands (switching desktops, screenshots) are ignored.
public final class VirtualDesktopsMeasure: Measure {
    private var measureType = ""

    public override func readMeasureOptions() {
        measureType = string("VDMeasureType").trimmingCharacters(in: .whitespaces).lowercased()
    }

    public override func computeValue() -> Double {
        rawString = nil
        switch measureType {
        case "vdmactive": return 0
        case "desktopcount", "desktopcountx", "desktopcounty", "currentdesktop": return 1
        case "desktopname":
            rawString = "Desktop 1"
            return 0
        case "screenshot":
            rawString = ""
            return 0
        default: return 0
        }
    }

    public override func execute(command: String) {
        sectionContext.logOnce("VirtualDesktops [\(name)]: \"\(command)\" ignored (macOS Spaces cannot be controlled)",
                     level: .notice)
    }
}
