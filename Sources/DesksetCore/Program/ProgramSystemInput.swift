import Foundation

public enum ProgramSystemProperty: String, CaseIterable, Equatable, Sendable {
    case cpuUsage = "cpu.usage"
    case cpuCoreCount = "cpu.coreCount"
    case memoryUsed = "memory.used"
    case memoryTotal = "memory.total"
    case memoryFree = "memory.free"
    case memoryUsage = "memory.usage"
    case batteryLevel = "battery.level"
    case batteryCharging = "battery.charging"
    case batteryPluggedIn = "battery.pluggedIn"
}

/// One projection's system data inputs. The host samples its injected system data source once; Core owns no live monitor.
public struct ProgramSystemInput: Equatable, Sendable {
    public let cpuUsage: Double? // 0...100
    public let cpuCoreCount: Int?
    public let memoryUsed: Double? // bytes
    public let memoryTotal: Double? // bytes
    public let memoryFree: Double? // bytes
    public let batteryLevel: Double? // 0...100
    public let batteryCharging: Bool?
    public let batteryPluggedIn: Bool?

    public init(cpuUsage: Double? = nil, cpuCoreCount: Int? = nil,
                memoryUsed: Double? = nil, memoryTotal: Double? = nil, memoryFree: Double? = nil,
                batteryLevel: Double? = nil, batteryCharging: Bool? = nil, batteryPluggedIn: Bool? = nil) {
        self.cpuUsage = cpuUsage
        self.cpuCoreCount = cpuCoreCount
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryFree = memoryFree
        self.batteryLevel = batteryLevel
        self.batteryCharging = batteryCharging
        self.batteryPluggedIn = batteryPluggedIn
    }

    /// Pure snapshot from a SystemDataSource without retaining it. Samples only the requested properties.
    public static func sample(from system: SystemDataSource,
                              for needed: Set<ProgramSystemProperty> = Set(ProgramSystemProperty.allCases)) -> ProgramSystemInput {
        guard !needed.isEmpty else { return ProgramSystemInput() }

        let cpuUsage: Double?
        if needed.contains(.cpuUsage) {
            let raw = system.cpuUsage(processor: 0)
            cpuUsage = (raw.isFinite && raw >= 0 && raw <= 100) ? raw : nil
        } else {
            cpuUsage = nil
        }

        let cpuCoreCount: Int?
        if needed.contains(.cpuCoreCount) {
            let count = system.processorCount
            cpuCoreCount = count > 0 ? count : nil
        } else {
            cpuCoreCount = nil
        }

        let memNeeded = needed.contains(.memoryUsed) || needed.contains(.memoryTotal) ||
                        needed.contains(.memoryFree) || needed.contains(.memoryUsage)
        let memUsed: Double?
        let memTotal: Double?
        let memFree: Double?
        if memNeeded {
            let mem = system.memoryStatus()
            let validTotal = mem.physicalTotal.isFinite && mem.physicalTotal > 0 ? mem.physicalTotal : nil
            let validUsed = mem.physicalUsed.isFinite && mem.physicalUsed >= 0 ? mem.physicalUsed : nil
            if let validTotal, let validUsed, validUsed <= validTotal {
                memTotal = validTotal
                memUsed = validUsed
                memFree = max(0, validTotal - validUsed)
            } else {
                memTotal = validTotal
                memUsed = nil
                memFree = nil
            }
        } else {
            memUsed = nil; memTotal = nil; memFree = nil
        }

        let batNeeded = needed.contains(.batteryLevel) || needed.contains(.batteryCharging) || needed.contains(.batteryPluggedIn)
        let batLevel: Double?
        let batCharging: Bool?
        let batPluggedIn: Bool?
        if batNeeded, let bat = system.battery() {
            batLevel = (bat.percent.isFinite && bat.percent >= 0 && bat.percent <= 100) ? bat.percent : nil
            batCharging = bat.isCharging
            batPluggedIn = bat.isPluggedIn
        } else {
            batLevel = nil; batCharging = nil; batPluggedIn = nil
        }

        return ProgramSystemInput(
            cpuUsage: cpuUsage,
            cpuCoreCount: cpuCoreCount,
            memoryUsed: memUsed,
            memoryTotal: memTotal,
            memoryFree: memFree,
            batteryLevel: batLevel,
            batteryCharging: batCharging,
            batteryPluggedIn: batPluggedIn
        )
    }
}
