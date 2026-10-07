import Foundation

/// An owner-scoped sampler and cache that enforces property cadences:
/// - CPU: 1s (periodic 1s boundary)
/// - Memory: 2s (periodic 2s boundary)
/// - Battery level: 60s (eventAndPeriodic 60s boundary)
/// - Battery status (charging / pluggedIn): event-driven (sampled on demand, refreshed on power events)
/// - Static properties (cpuCoreCount, memoryTotal): once (sampled on demand, never re-read)
public struct ProgramSystemSampler: Sendable {
    private var lastCPUPeriod: Double?
    private var cachedCPU: Double?

    private var hasCoreCount = false
    private var cachedCoreCount: Int?

    private var lastMemoryPeriod: Double?
    private var cachedMemoryStatus: MemoryStatus?
    private var hasMemoryTotal = false
    private var cachedMemoryTotal: Double?

    private var lastBatteryPeriod: Double?
    private var hasBattery = false
    private var cachedBatteryStatus: BatteryStatus?

    private var lastInstant: TimeInterval?

    public init() {}

    private static func period(for instant: TimeInterval, interval: Double) -> Double? {
        guard instant.isFinite else { return nil }
        return floor(instant / interval)
    }

    /// Samples needed properties from the data source, respecting each property's cadence.
    /// Returns an immutable ProgramSystemInput snapshot, or nil if no properties are needed.
    public mutating func sample(from system: SystemDataSource, for needed: Set<ProgramSystemProperty>, at now: TimeInterval) -> ProgramSystemInput? {
        guard !needed.isEmpty, now.isFinite else { return nil }

        // Clock jump backwards: invalidate time-based caches so new values are sampled immediately.
        if let last = lastInstant, now < last {
            invalidateTimeBased()
        }
        lastInstant = now

        // 1. CPU (cadence 1s boundary)
        var cpuUsage: Double?
        if needed.contains(.cpuUsage) {
            let p = Self.period(for: now, interval: 1.0)
            if let p, p == lastCPUPeriod {
                cpuUsage = cachedCPU
            } else {
                let reading = system.cpuUsage(processor: 0)
                if reading.isFinite, (0...100).contains(reading) {
                    cachedCPU = reading
                    cpuUsage = reading
                } else {
                    cachedCPU = nil
                    cpuUsage = nil
                }
                lastCPUPeriod = p
            }
        }

        // 2. CPU Core Count (cadence once: sample once on demand, do not re-read)
        var cpuCoreCount: Int?
        if needed.contains(.cpuCoreCount) {
            if !hasCoreCount {
                hasCoreCount = true
                let count = system.processorCount
                if count >= 1 {
                    cachedCoreCount = count
                } else {
                    cachedCoreCount = nil
                }
            }
            cpuCoreCount = cachedCoreCount
        }

        // 3. Memory (used / free / usage: cadence 2s boundary; total: cadence once)
        let needsDynamicMemory = needed.contains(.memoryUsed) || needed.contains(.memoryFree) || needed.contains(.memoryUsage)
        let needsMemoryTotal = needed.contains(.memoryTotal) || needed.contains(.memoryUsage)

        var turnMemoryReading: MemoryStatus?
        if needsDynamicMemory {
            let p = Self.period(for: now, interval: 2.0)
            if let p, p == lastMemoryPeriod {
                // use cachedMemoryStatus
            } else {
                let status = system.memoryStatus()
                turnMemoryReading = status
                lastMemoryPeriod = p
                if status.physicalTotal.isFinite, status.physicalTotal > 0,
                   status.physicalUsed.isFinite, status.physicalUsed >= 0, status.physicalUsed <= status.physicalTotal {
                    cachedMemoryStatus = status
                } else {
                    cachedMemoryStatus = nil
                }
            }
        }

        if needsMemoryTotal && !hasMemoryTotal {
            hasMemoryTotal = true
            let total: Double
            if let raw = turnMemoryReading {
                total = raw.physicalTotal
            } else if let cached = cachedMemoryStatus {
                total = cached.physicalTotal
            } else {
                let reading = system.memoryStatus()
                turnMemoryReading = reading
                total = reading.physicalTotal
            }
            if total.isFinite, total > 0 {
                cachedMemoryTotal = total
            } else {
                cachedMemoryTotal = nil
            }
        }

        let memoryUsed = needed.contains(.memoryUsed) || needed.contains(.memoryUsage) ? cachedMemoryStatus?.physicalUsed : nil
        let memoryFree = needed.contains(.memoryFree) ? (cachedMemoryStatus.map { max($0.physicalTotal - $0.physicalUsed, 0) }) : nil
        let memoryTotal = needsMemoryTotal ? cachedMemoryTotal : nil

        // 4. Battery (level: cadence 60s boundary + event; charging/pluggedIn: event-driven)
        let needsBatteryLevel = needed.contains(.batteryLevel)
        let needsBatteryEvent = needed.contains(.batteryCharging) || needed.contains(.batteryPluggedIn)

        if needsBatteryLevel {
            let p = Self.period(for: now, interval: 60.0)
            if let p, p == lastBatteryPeriod, hasBattery {
                // use cachedBatteryStatus
            } else {
                hasBattery = true
                cachedBatteryStatus = system.battery()
                lastBatteryPeriod = p
            }
        } else if needsBatteryEvent && !hasBattery {
            hasBattery = true
            cachedBatteryStatus = system.battery()
            lastBatteryPeriod = Self.period(for: now, interval: 60.0)
        }

        var batteryLevel: Double?
        if needsBatteryLevel, let b = cachedBatteryStatus, b.percent.isFinite, (0...100).contains(b.percent) {
            batteryLevel = b.percent
        }
        var batteryCharging: Bool?
        if needed.contains(.batteryCharging) {
            batteryCharging = cachedBatteryStatus?.isCharging ?? false
        }
        var batteryPluggedIn: Bool?
        if needed.contains(.batteryPluggedIn) {
            batteryPluggedIn = cachedBatteryStatus?.isPluggedIn ?? false
        }

        return ProgramSystemInput(
            cpuUsage: cpuUsage,
            cpuCoreCount: cpuCoreCount,
            memoryUsed: memoryUsed,
            memoryTotal: memoryTotal,
            memoryFree: memoryFree,
            batteryLevel: batteryLevel,
            batteryCharging: batteryCharging,
            batteryPluggedIn: batteryPluggedIn
        )
    }

    /// Invalidates battery cache when power source notification arrives.
    public mutating func invalidateBattery() {
        lastBatteryPeriod = nil
        hasBattery = false
        cachedBatteryStatus = nil
    }

    /// Invalidates time-based caches (CPU, memory, battery) when system wakes or clock jumps.
    public mutating func invalidateTimeBased() {
        lastCPUPeriod = nil
        lastMemoryPeriod = nil
        lastBatteryPeriod = nil
        hasBattery = false
        cachedBatteryStatus = nil
    }

    /// Resets all caches (e.g. on host reset).
    public mutating func reset() {
        lastCPUPeriod = nil
        cachedCPU = nil
        hasCoreCount = false
        cachedCoreCount = nil
        lastMemoryPeriod = nil
        cachedMemoryStatus = nil
        hasMemoryTotal = false
        cachedMemoryTotal = nil
        lastBatteryPeriod = nil
        hasBattery = false
        cachedBatteryStatus = nil
        lastInstant = nil
    }
}
