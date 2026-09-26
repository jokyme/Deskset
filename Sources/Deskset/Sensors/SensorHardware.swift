import DesksetCore
import Foundation
import IOKit

/// A group of sensors read together: one SMC pass, one IOReport sample, one registry lookup.
enum SensorGroup: String, CaseIterable {
    /// SMC temperature keys (HID sensors when the SMC has no CPU temperatures).
    case temperatures
    /// SMC fan keys.
    case fans
    /// SMC whole-Mac power keys.
    case systemPower
    /// IOReport energy and clock states (Apple silicon).
    case ioReport
    /// The graphics accelerators' statistics.
    case gpu
    /// AppleSmartBattery.
    case battery

    /// The groups that can answer a catalog key (canonical), in the order they are asked; empty for other names.
    static func groups(for key: String) -> [SensorGroup] {
        switch key {
        case SensorKeys.gpu: return [.temperatures, .gpu]
        case SensorKeys.battery: return [.temperatures, .battery]
        case SensorKeys.powerSystem, SensorKeys.powerAdapter: return [.systemPower]
        case SensorKeys.frequencyGPU: return [.ioReport, .gpu]
        case SensorKeys.frequencyGPUMemory: return [.gpu]
        case SensorKeys.voltageCPU: return [.ioReport]
        default: break
        }
        guard let kind = SensorKeys.kind(of: key) else { return [] }
        if key.hasPrefix("fan.") { return [.fans] }
        if key.hasPrefix("battery.") { return [.battery] }
        if key.hasPrefix("gpu.") { return [.gpu] }
        if key.hasPrefix("power.") || key.hasPrefix("frequency.") { return [.ioReport] }
        return kind == .temperature ? [.temperatures] : []
    }
}

/// What the sensor service reads the hardware with; the self-tests use fakes.
protocol SensorHardware: AnyObject {
    /// Reads `groups`. Called on the sensor service's queue only, one call at a time; may take a while.
    func read(_ groups: Set<SensorGroup>, now: TimeInterval) -> [SensorGroup: SensorGroupReading]
    /// Lets go of what `groups` hold (the IOReport subscription…) while nothing asks for them. Same queue.
    func release(_ groups: Set<SensorGroup>)
    /// The nominal maximum junction temperature of this Mac's CPU (°C).
    var tjMax: Double { get }
}

/// The Mac's sensors: SMC, HID, IOReport, IOKit. Confined to the sensor service's queue (created anywhere; it looks
/// at nothing until its first read).
final class LiveSensorHardware: SensorHardware {
    let family: ChipFamily
    private lazy var coreTypes: [CoreType] = family.isAppleSilicon ? IOReportSampler.coreTypes() : []
    private lazy var physicalCores = SensorSystemInfo.int("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
    /// Where the list of the SMC's temperature keys is kept between launches (nil: not kept), asked when needed.
    private let keyCacheURL: () -> URL?

    private var smc: SMCConnection?
    private var smcTried = false
    private var temperatureKeys: [String]?
    private var hid: HIDTemperatureReader?
    private var hidTried = false
    private var ioReport: IOReportSampler?
    private var ioReportTried = false

    init(family: ChipFamily = .current, keyCacheURL: @escaping () -> URL? = { LiveSensorHardware.keyCacheURL.current }) {
        self.family = family
        self.keyCacheURL = keyCacheURL
    }

    /// Where the app keeps the SMC key list: ~/Library/Caches/Deskset/Sensors/smc-keys.json. The self-tests set nil
    /// (nothing is kept, every run walks the keys).
    static let keyCacheURL = Guarded<URL?>({
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return caches.appendingPathComponent("Deskset/Sensors/smc-keys.json")
    }())

    /// Apple publishes no junction limit for its chips: 110 °C is about the highest core temperature reported under
    /// sustained load. Intel: 100 °C, the limit of most processors Macs used.
    var tjMax: Double { family.isAppleSilicon ? 110 : 100 }

    func read(_ groups: Set<SensorGroup>, now: TimeInterval) -> [SensorGroup: SensorGroupReading] {
        var result: [SensorGroup: SensorGroupReading] = [:]
        for group in SensorGroup.allCases where groups.contains(group) {
            switch group {
            case .temperatures: result[group] = temperatures()
            case .fans: result[group] = SensorReadings.fans { openSMC()?.number($0) }
            case .systemPower: result[group] = SensorReadings.systemPower { openSMC()?.number($0) }
            case .ioReport: result[group] = ioReportReading(now: now)
            case .gpu: result[group] = SensorReadings.gpu(IOKitSensorReaders.acceleratorStatistics())
            case .battery: result[group] = IOKitSensorReaders.batteryProperties().map(SensorReadings.battery)
                ?? SensorGroupReading()
            }
        }
        return result
    }

    func release(_ groups: Set<SensorGroup>) {
        if groups.contains(.ioReport), ioReport != nil || ioReportTried {
            ioReport = nil
            ioReportTried = false
        }
    }

    private func openSMC() -> SMCConnection? {
        if !smcTried {
            smcTried = true
            smc = SMCConnection()
        }
        return smc
    }

    // MARK: Temperatures

    private func temperatures() -> SensorGroupReading {
        var reading = SensorGroupReading()
        if let smc = openSMC() {
            let keys = temperatureKeys ?? discoverTemperatureKeys(smc)
            var values: [String: Double] = [:]
            for key in keys {
                if let v = smc.number(key) { values[key] = v }
            }
            reading = SensorReadings.smcTemperatures(values, family: family, coreTypes: coreTypes,
                                                     physicalCores: physicalCores)
        }
        if !reading.infos.contains(where: { $0.key == SensorKeys.cpu }) {
            // No CPU temperature from the SMC: the HID sensors, for whatever the SMC lacks.
            if !hidTried {
                hidTried = true
                hid = HIDTemperatureReader()
            }
            if let hid {
                let extra = SensorReadings.hidTemperatures(hid.read(), family: family, coreTypes: coreTypes,
                                                           physicalCores: physicalCores)
                for info in extra.infos where !reading.infos.contains(where: { $0.key == info.key }) {
                    reading.add(info, extra.values[info.key])
                }
                reading.infos.sort { SensorGroupReading.order($0.key) < SensorGroupReading.order($1.key) }
            }
        }
        return reading
    }

    /// The SMC's temperature keys: from the list kept for this Mac model and macOS build, else by walking every key
    /// (about a second on an M4 Pro, once), then kept.
    private func discoverTemperatureKeys(_ smc: SMCConnection) -> [String] {
        let model = SensorSystemInfo.string("hw.model") ?? ""
        let build = SensorSystemInfo.string("kern.osversion") ?? ""
        let cacheURL = keyCacheURL()
        if let url = cacheURL, let list = SMCKeyList.load(url), list.model == model, list.build == build {
            smc.remember(list.keys)
            let keys = SensorReadings.temperatureKeys(list.keys, family: family)
            temperatureKeys = keys
            return keys
        }
        var found: [String: SMCKeyInfo] = [:]
        let count = min(smc.keyCount(), 10_000)
        for index in 0..<count {
            guard let key = smc.key(at: index), key.description.hasPrefix("T"), let info = smc.info(key),
                  SMCValue.isNumeric(info.type) else { continue }
            found[key.description] = info
        }
        if let url = cacheURL, count > 0 {
            SMCKeyList(model: model, build: build, keys: found).save(url)
        }
        let keys = SensorReadings.temperatureKeys(found, family: family)
        temperatureKeys = keys
        return keys
    }

    // MARK: IOReport

    private func ioReportReading(now: TimeInterval) -> SensorGroupReading {
        guard family.isAppleSilicon else { return SensorGroupReading() }
        if !ioReportTried {
            ioReportTried = true
            ioReport = IOReportSampler(coreTypes: coreTypes)
            // A first sample to measure from, so that this reading already has values.
            if let sampler = ioReport {
                _ = sampler.sample(now: now)
                Thread.sleep(forTimeInterval: 0.25)
                return sampler.sample(now: now + 0.25) ?? SensorGroupReading()
            }
        }
        return ioReport?.sample(now: now) ?? SensorGroupReading()
    }
}

/// The SMC's temperature keys of one Mac model and macOS build, kept on disk: walking every key takes about a second.
struct SMCKeyList: Codable, Equatable {
    var version = 1
    var model: String
    var build: String
    var keys: [String: SMCKeyInfo]

    static func load(_ url: URL) -> SMCKeyList? {
        guard let data = try? Data(contentsOf: url), data.count < 4 << 20,
              let list = try? JSONDecoder().decode(SMCKeyList.self, from: data), list.version == 1 else { return nil }
        return list
    }

    func save(_ url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Registry readings: the graphics accelerators' statistics and the battery's properties.
enum IOKitSensorReaders {
    /// `PerformanceStatistics` of every IOAccelerator (Rosetta adds one without statistics; it is left out).
    static func acceleratorStatistics() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
                == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [[String: Any]] = []
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard result.count < 16,
                  let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString,
                                                              kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            else { continue }
            result.append(stats)
        }
        return result
    }

    /// The AppleSmartBattery properties the battery group uses; nil without a battery.
    static func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var result: [String: Any] = [:]
        for key in ["DesignCapacity", "AppleRawMaxCapacity", "MaxCapacity", "CycleCount", "DesignCycleCount9C",
                    "Voltage", "Amperage", "InstantAmperage", "Temperature"] {
            if let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() {
                result[key] = value
            }
        }
        return result.isEmpty ? nil : result
    }
}
