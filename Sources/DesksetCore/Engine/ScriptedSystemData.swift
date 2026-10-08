import Foundation

/// The system readings of `SkinInputData` (`system`, `battery`, `sensors`, `desktopImage`) in front of a live source:
/// what the data gives comes from it, the rest from `base`. The system readings are a sequence of frames: the first
/// one is current until `advance()` moves to the next (a render advances once before every update after the first);
/// after the last frame the last one stays. With `system` given, every reading of `SystemDataSource` but the battery
/// and the desktop picture comes from the frames — one the frames never give is 0, empty or unknown, never the Mac's —
/// so the same data gives the same readings on every Mac. The processes of a frame are also what UsageMonitor,
/// AdvancedCPU and PerfMon see (`ProcessSampleSource`): one second of the Mac at the shares of the frame.
///
/// Thread-safe: a skin reads it from its own thread, a render or a script moves it on from another.
public final class ScriptedSystemData: SystemDataSource, HardwareSensorSource, @unchecked Sendable {
    public let base: SystemDataSource
    private let lock = NSLock()
    private var frames: [SkinInputData.SystemFrame]
    private var index = 0
    private var batteryGiven: SkinInputData.Given<BatteryStatus>?
    private var batteryDetailsGiven: SkinInputData.Given<BatteryDetails>?
    private var sensorValues: [String: SkinInputData.Sensor]?
    private var thermal: Int?
    private var desktop: SkinInputData.Given<String>?

    public init(base: SystemDataSource, data: SkinInputData) {
        self.base = base
        frames = data.system ?? []
        batteryGiven = data.battery
        batteryDetailsGiven = data.batteryDetails
        sensorValues = data.sensors
        thermal = data.thermalState
        desktop = data.desktopImage
    }

    /// Whether the data gives the readings of `kind` (`.system`, `.battery`, `.sensors`): the skin's reads of them
    /// then depend on the data, not on the Mac (`Skin.noteService`).
    public func gives(_ kind: BackgroundWorkKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .system: return !frames.isEmpty
        case .battery: return batteryGiven != nil || batteryDetailsGiven != nil
        case .sensors: return sensorValues != nil || thermal != nil
        default: return false
        }
    }

    /// Moves to the next frame (the last one stays current).
    public func advance() {
        lock.lock()
        if index < frames.count - 1 { index += 1 }
        lock.unlock()
    }

    /// The frame shown now (0-based).
    public var frameIndex: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    /// Replaces what `data` gives (an event script's `data` step); the rest stays. New system frames start over at
    /// their first.
    public func apply(_ data: SkinInputData) {
        lock.lock()
        if let system = data.system {
            frames = system
            index = 0
        }
        if let battery = data.battery {
            batteryGiven = battery
            // An old-schema replacement also replaces earlier details with unavailable values.
            batteryDetailsGiven = data.batteryDetails
        } else if let details = data.batteryDetails {
            batteryDetailsGiven = details
        }
        if let sensors = data.sensors { sensorValues = sensors }
        if let t = data.thermalState { thermal = t }
        if let d = data.desktopImage { desktop = d }
        lock.unlock()
    }

    /// The current frame; nil when `system` is not given (the Mac's readings).
    private var frame: SkinInputData.SystemFrame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.isEmpty ? nil : frames[index]
    }

    // MARK: SystemDataSource

    /// The cores the frames give (the longest `cpu` list less the whole CPU), at least 1.
    public var processorCount: Int {
        lock.lock()
        let given = !frames.isEmpty
        let most = frames.compactMap { $0.cpu?.count }.max() ?? 0
        lock.unlock()
        return given ? max(most - 1, 1) : base.processorCount
    }

    public func cpuUsage(processor: Int) -> Double {
        guard let f = frame else { return base.cpuUsage(processor: processor) }
        let cpu = f.cpu ?? []
        return processor >= 0 && processor < cpu.count ? cpu[processor] : 0
    }

    public func memoryStatus() -> MemoryStatus {
        guard let f = frame else { return base.memoryStatus() }
        return f.memory ?? MemoryStatus()
    }

    public func networkInterfaces() -> [String] {
        guard let f = frame else { return base.networkInterfaces() }
        return (f.network ?? [:]).keys.sorted()
    }

    public func networkCounters(interface: String?) -> NetworkCounters {
        guard let f = frame else { return base.networkCounters(interface: interface) }
        let network = f.network ?? [:]
        if let interface { return network[interface] ?? NetworkCounters() }
        return network.values.reduce(NetworkCounters()) {
            NetworkCounters(received: $0.received &+ $1.received, sent: $0.sent &+ $1.sent)
        }
    }

    public func bestNetworkInterface() -> String? {
        guard let f = frame else { return base.bestNetworkInterface() }
        return f.bestInterface ?? (f.network ?? [:]).keys.sorted().first
    }

    /// The volume holding `path` (the disk with the longest mount point `path` is in; nil: none), or nil when
    /// `system` is not given.
    private func disk(_ path: String) -> SkinInputData.Disk?? {
        guard let f = frame else { return nil }
        let disks = f.disks ?? [:]
        let p = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let mount = disks.keys.filter { m in
            m == "/" || p == m || p.hasPrefix(m.hasSuffix("/") ? m : m + "/")
        }.max { $0.count < $1.count }
        return .some(mount.flatMap { disks[$0] })
    }

    public func diskSpace(path: String) -> (total: Double, free: Double)? {
        guard let d = disk(path) else { return base.diskSpace(path: path) }
        return d.map { ($0.total, $0.free) }
    }

    public func availableDiskSpace(path: String) -> Double? {
        guard let d = disk(path) else { return base.availableDiskSpace(path: path) }
        return d.map { $0.available ?? $0.free }
    }

    public func volumeInfo(path: String) -> VolumeInfo? {
        guard let d = disk(path) else { return base.volumeInfo(path: path) }
        return d.map { VolumeInfo(label: $0.label, kind: $0.kind) }
    }

    public func uptime() -> TimeInterval {
        guard let f = frame else { return base.uptime() }
        return f.uptime ?? 0
    }

    public func battery() -> BatteryStatus? {
        lock.lock()
        let given = batteryGiven
        lock.unlock()
        guard let given else { return base.battery() }
        return given.value
    }

    public func batteryDetails() -> BatteryDetailsReading {
        lock.lock()
        let given = batteryDetailsGiven, hasBattery = batteryGiven != nil
        lock.unlock()
        if let given { return .ready(given.value ?? BatteryDetails()) }
        if hasBattery { return .ready(BatteryDetails()) }
        return base.batteryDetails()
    }

    public func isProcessRunning(_ name: String) -> Bool {
        guard let f = frame else { return base.isProcessRunning(name) }
        return (f.processes ?? []).contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `TYPE:data` for that SysInfoData, else `TYPE`; a type the frames do not give has no answer here.
    public func sysInfo(type: String, data: String) -> (number: Double, string: String?)? {
        guard let f = frame else { return base.sysInfo(type: type, data: data) }
        let key = type.uppercased()
        let answers = f.sysInfo ?? [:]
        guard let a = (data.isEmpty ? nil : answers["\(key):\(data)"]) ?? answers[key] else { return nil }
        return (a.number, a.string)
    }

    public func cpuFrequency() -> Double? {
        guard let f = frame else { return base.cpuFrequency() }
        return f.cpuFrequency
    }

    public func desktopPicturePath() -> String? {
        lock.lock()
        let given = desktop
        lock.unlock()
        guard let given else { return base.desktopPicturePath() }
        return given.value ?? ""
    }

    public func graphicsAdapterName() -> String? {
        guard let f = frame else { return base.graphicsAdapterName() }
        return f.graphicsAdapter
    }

    // MARK: HardwareSensorSource

    private var sensors: [String: SkinInputData.Sensor]? {
        lock.lock()
        defer { lock.unlock() }
        return sensorValues
    }

    private var liveSensors: HardwareSensorSource? { base as? HardwareSensorSource }

    private func info(_ key: String, _ s: SkinInputData.Sensor) -> SensorInfo? {
        guard let kind = SensorKeys.kind(of: key) else { return nil }
        return SensorInfo(key: key, label: s.label ?? key, kind: kind, minimum: s.minimum, maximum: s.maximum,
                          source: "--data")
    }

    public func sensorList() -> [SensorInfo] {
        guard let sensors else { return liveSensors?.sensorList() ?? [] }
        return sensors.sorted { $0.key < $1.key }.compactMap { info($0.key, $0.value) }
    }

    public func sensorInfo(_ key: String) -> SensorInfo? {
        guard let sensors else { return liveSensors?.sensorInfo(key) }
        let k = SensorKeys.canonical(key)
        return sensors[k].flatMap { info(k, $0) }
    }

    public func sensorValue(_ key: String) -> Double? {
        guard let sensors else { return liveSensors?.sensorValue(key) }
        let k = SensorKeys.canonical(key)
        if let v = sensors[k]?.value { return v }
        // `fan.1.max` and `fan.1.min`: the fan's own range when only that is given.
        let parts = k.split(separator: ".")
        if parts.count == 3, parts[0] == "fan", let fan = sensors["fan.\(parts[1])"] {
            if parts[2] == "max" { return fan.maximum }
            if parts[2] == "min" { return fan.minimum }
        }
        return nil
    }

    public func sensorPending(_ key: String) -> Bool {
        guard sensors != nil else { return liveSensors?.sensorPending(key) ?? false }
        return false
    }

    public func discoverSensors(_ done: @escaping ([SensorInfo]) -> Void) {
        guard sensors != nil else {
            if let liveSensors { liveSensors.discoverSensors(done) } else { done([]) }
            return
        }
        done(sensorList())
    }

    public func cpuTjMax() -> Double? {
        guard sensors != nil else { return liveSensors?.cpuTjMax() }
        return nil
    }

    public func thermalState() -> Int? {
        lock.lock()
        let t = thermal
        lock.unlock()
        return t ?? liveSensors?.thermalState()
    }
}

// MARK: - Processes

extension ScriptedSystemData: ProcessSampleSource {
    /// The processes of the frames as samples one second apart, cumulative like the Mac's counters: during frame k
    /// each process used its share of every core's time for one second, and what the cores were busy with beyond the
    /// processes is the synthetic "System". `latest` is frame k, `previous` frame k − 1 (before the first frame: every
    /// counter at 0). nil when the current frame has no processes (the shared sampler then).
    func processSamples() -> (previous: ProcessSnapshot?, latest: ProcessSnapshot?)? {
        lock.lock()
        let list = frames
        let k = index
        lock.unlock()
        guard k < list.count, list[k].processes != nil else { return nil }
        let cores = processorCount
        let second = 10_000_000.0
        func busy(_ f: SkinInputData.SystemFrame) -> [Double] {
            let cpu: [Double] = f.cpu ?? []
            let whole: Double = cpu.first ?? 0
            return (0..<cores).map { (i: Int) -> Double in
                let load: Double = i + 1 < cpu.count ? cpu[i + 1] : whole
                return load / 100 * second
            }
        }
        /// The counters after frames 0…j (j = −1: before the first).
        func snapshot(_ j: Int) -> ProcessSnapshot {
            var coreBusy = [Double](repeating: 0, count: cores)
            var used: [Int32: Double] = [:]
            var hidden = 0.0
            if j >= 0 {
                for f in list[0...j] {
                    let b = busy(f)
                    for i in 0..<cores { coreBusy[i] += b[i] }
                    var visible = 0.0
                    for p in f.processes ?? [] {
                        let t = p.cpu / 100 * Double(cores) * second
                        used[p.pid, default: 0] += t
                        visible += t
                    }
                    hidden += max(0, b.reduce(0, +) - visible)
                }
            }
            let shown = list[max(j, 0)].processes ?? []
            let records = shown.map { p in
                ProcessRecord(pid: p.pid, name: p.name, start: 1, userTime: used[p.pid] ?? 0, residentBytes: p.memory,
                              footprintBytes: p.memory, threads: 1, elapsed: 3600 + Double(j + 1))
            }
            let seconds = Double(j + 1)
            return ProcessSnapshot(serial: j + 2, time: 1000 + seconds, processes: records.sorted { $0.pid < $1.pid },
                                   processCount: shown.count,
                                   cores: coreBusy.map { CoreTicks(user: $0, system: 0, idle: seconds * second - $0,
                                                                   nice: 0) },
                                   hiddenCPU: hidden)
        }
        return (snapshot(k - 1), snapshot(k))
    }
}
