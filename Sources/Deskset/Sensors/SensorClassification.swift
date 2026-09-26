import DesksetCore
import Foundation

// Which SMC temperature key (and which HID temperature sensor) measures what, and which readings to trust.
//
// Apple documents none of this. The rules come from observing Macs (key names, how their readings follow load) and
// are deliberately coarse: a two-letter prefix per role, a small table per chip family, and a validity filter. When a
// new chip uses new names, the catalog simply lacks those sensors until the table learns them; nothing breaks.
// Verified on an M4 Pro; the M1–M3 and Intel rules are untested (docs/compat/plugins.md).

/// The kind of processor, which decides the key names.
enum ChipFamily: Equatable {
    /// Apple silicon, with its generation (1 = M1 …); 0 when the name does not say (the newest rules then apply).
    case appleSilicon(generation: Int)
    case intel

    /// From the processor's brand string ("Apple M4 Pro", "Intel(R) Core(TM) i9-9980HK …") and whether the hardware
    /// is Apple silicon (`hw.optional.arm64`, also true for an Intel build running under Rosetta).
    static func from(brand: String, isAppleSilicon: Bool) -> ChipFamily {
        guard isAppleSilicon else { return .intel }
        if let r = brand.range(of: #"\bM(\d+)"#, options: .regularExpression),
           let n = Int(brand[r].dropFirst()) {
            return .appleSilicon(generation: n)
        }
        return .appleSilicon(generation: 0)
    }

    /// This Mac's family.
    static let current: ChipFamily = {
        var arm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let isARM = sysctlbyname("hw.optional.arm64", &arm, &size, nil, 0) == 0 && arm == 1
        return from(brand: SensorSystemInfo.string("machdep.cpu.brand_string") ?? "", isAppleSilicon: isARM)
    }()

    var description: String {
        switch self {
        case .appleSilicon(let generation): return generation > 0 ? "Apple M\(generation) family" : "Apple silicon"
        case .intel: return "Intel"
        }
    }

    var isAppleSilicon: Bool {
        if case .appleSilicon = self { return true }
        return false
    }
}

/// What a temperature sensor measures.
enum TemperatureRole: Hashable {
    case cpuPerformance
    case cpuEfficiency
    /// A CPU sensor whose cluster is not known (M1, M2: one prefix for both clusters; Intel: the package).
    case cpu
    /// An Intel core's own sensor, by the digit of its key (`TC<d>C`). Macs number these keys from 0 or from 1;
    /// `SensorReadings.intelCoreKeys` decides which core each one is.
    case cpuCore(Int)
    case gpu
    /// The rest of the chip (Apple silicon) or the chipset (Intel).
    case soc
    case battery
    case ssd

    var isCPU: Bool {
        switch self {
        case .cpuPerformance, .cpuEfficiency, .cpu, .cpuCore: return true
        default: return false
        }
    }
}

enum SensorClassification {
    /// The role of an SMC temperature key (`T…`), or nil for keys the catalog does not use (ambient, palm rest,
    /// voltage regulators, the battery gas gauge's own sensors on Apple silicon, limits…).
    static func role(ofSMCKey key: String, family: ChipFamily) -> TemperatureRole? {
        let c = Array(key.utf8)
        guard c.count == 4, c[0] == UInt8(ascii: "T") else { return nil }
        let prefix = String(key.prefix(2))
        // Both families: battery TB0T, TB1T…; SSD TH0x, TH0a…
        if prefix == "TB", c[3] == UInt8(ascii: "T"), isDigit(c[2]) { return .battery }
        if prefix == "TH" { return .ssd }
        switch family {
        case .appleSilicon(let generation):
            switch prefix {
            case "Tp":
                // M4 and later: the performance cores; M1 / M2: every core (the clusters share the prefix); M3 uses
                // Tf for its cores instead.
                if generation == 1 || generation == 2 { return .cpu }
                return generation == 3 ? nil : .cpuPerformance
            case "Te":
                return .cpuEfficiency
            case "Tf":
                // M3 (reported): performance cores at Tf0x / Tf4x, GPU at Tf1x / Tf2x. Other chips: not a CPU key.
                guard generation == 3 else { return nil }
                switch c[2] {
                case UInt8(ascii: "0"), UInt8(ascii: "4"): return .cpuPerformance
                case UInt8(ascii: "1"), UInt8(ascii: "2"): return .gpu
                default: return nil
                }
            case "Tg":
                return .gpu
            case "Ts":
                // Ts0P / Ts1P are the palm rest (a surface, not the chip).
                return c[3] == UInt8(ascii: "P") ? nil : .soc
            default:
                return nil
            }
        case .intel:
            switch prefix {
            case "TC":
                // TC1C, TC2C… (TC0C, TC1C… on some Macs): one core each; TCGC: the integrated GPU; TCSA / TCSC: the
                // system agent; the rest (TC0P proximity, TC0D / TC0E / TC0F die, TCXC PECI…) describe the whole CPU.
                if isDigit(c[2]), c[3] == UInt8(ascii: "C") { return .cpuCore(Int(c[2] - UInt8(ascii: "0"))) }
                if c[2] == UInt8(ascii: "G") { return .gpu }
                if c[2] == UInt8(ascii: "S") { return .soc }
                return .cpu
            case "TG":
                return .gpu
            case "TP":
                return key == "TPCD" ? .soc : nil
            default:
                return nil
            }
        }
    }

    /// The role of a HID temperature sensor by its product name, for Macs whose SMC gives no CPU temperatures (the
    /// HID names of M1 / M2 Macs say which cluster a sensor is on).
    static func role(ofHIDName name: String) -> TemperatureRole? {
        let n = name.lowercased()
        if n.contains("pacc") { return .cpuPerformance }
        if n.contains("eacc") { return .cpuEfficiency }
        if n.contains("gpu") { return .gpu }
        if n.contains("nand") { return .ssd }
        if n.contains("battery") { return .battery }
        if n.contains("soc") || n.contains("tdie") { return .soc }
        return nil
    }

    /// Whether a temperature reading is real: within 10–130 °C, and not the 40.0 °C some Apple silicon CPU keys
    /// report exactly, like the readings of −4…5 °C, while their cluster is powered down.
    static func isValid(_ celsius: Double, role: TemperatureRole, family: ChipFamily) -> Bool {
        guard celsius.isFinite, celsius > 10, celsius < 130 else { return false }
        if family.isAppleSilicon, role.isCPU, celsius == 40 { return false }
        return true
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9") }
}

/// sysctl helpers for the sensor code.
enum SensorSystemInfo {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    static func int(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
