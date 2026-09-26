import AppKit
import DesksetCore

/// The hardware sensors (Sources/Deskset/Sensors): SMC value decoding and the read-only request blocks, key
/// classification from fixture tables of M-series and Intel Macs, the validity filter, the catalog, the IOKit
/// dictionaries, IOReport's tables and arithmetic, the key list kept on disk, the sensor service's lazy background
/// reading from several threads, the wiring into skins through `SystemMonitor`, and a live smoke test that accepts
/// "no reading" (CI's virtual machines have no sensors) but no implausible one.
enum SensorSelfTests {
    typealias Collected = SharedServiceThreadingSelfTests.Collected

    static func run(_ t: AppTestRunner) {
        // No SMC key list is kept on disk during the self-tests.
        LiveSensorHardware.keyCacheURL.access { $0 = nil }
        smcTests(t)
        classificationTests(t)
        dictionaryTests(t)
        ioReportTests(t)
        catalogTests(t)
        serviceTests(t)
        threadingTests(t)
        wiringTests(t)
        liveTests(t)
    }

    // MARK: SMC

    static func smcTests(_ t: AppTestRunner) {
        t.suite("App: sensors: SMC values decode by type") {
            func le32(_ f: Float) -> [UInt8] { withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) } }
            t.equal(SMCValue.decode(type: "flt ", bytes: le32(34.5)), 34.5, "little-endian float (Apple silicon)")
            t.equal(SMCValue.decode(type: "flt ", bytes: le32(2317)), 2317)
            t.equal(SMCValue.decode(type: "flt ", bytes: [0, 0, 0xc0, 0x7f]), nil, "NaN is no reading")
            t.equal(SMCValue.decode(type: "flt ", bytes: [1, 2]), nil, "wrong size")
            // ioft: 48.16 fixed point, little-endian: 34.75 = 0x22_C000.
            t.equal(SMCValue.decode(type: "ioft", bytes: [0x00, 0xc0, 0x22, 0, 0, 0, 0, 0]), 34.75)
            // sp78: signed 7.8, big-endian (Intel temperatures): 0x2280 = 34.5; 0xFF00 = -1.
            t.equal(SMCValue.decode(type: "sp78", bytes: [0x22, 0x80]), 34.5)
            t.equal(SMCValue.decode(type: "sp78", bytes: [0xff, 0x00]), -1)
            // fpe2: unsigned 14.2, big-endian (older Intel fans): 2317 RPM = 9268 = 0x2434.
            t.equal(SMCValue.decode(type: "fpe2", bytes: [0x24, 0x34]), 2317)
            t.equal(SMCValue.decode(type: "fp88", bytes: [0x01, 0x80]), 1.5)
            t.equal(SMCValue.decode(type: "ui8 ", bytes: [2]), 2)
            t.equal(SMCValue.decode(type: "ui16", bytes: [0x01, 0x02]), 258, "integers are big-endian")
            t.equal(SMCValue.decode(type: "ui32", bytes: [0, 0, 0x0c, 0xae]), 3246)
            t.equal(SMCValue.decode(type: "ui64", bytes: [0, 0, 0, 0, 0, 0, 1, 0]), 256)
            t.equal(SMCValue.decode(type: "si8 ", bytes: [0xfe]), -2)
            t.equal(SMCValue.decode(type: "si16", bytes: [0xff, 0xfe]), -2)
            t.equal(SMCValue.decode(type: "si32", bytes: [0xff, 0xff, 0xff, 0xfd]), -3)
            t.equal(SMCValue.decode(type: "flag", bytes: [1]), 1)
            t.equal(SMCValue.decode(type: "ui16", bytes: [1]), nil)
            for type in ["ch8*", "hex_", "{fds", "fpzz", "xx78"] {
                t.equal(SMCValue.decode(type: type, bytes: [1, 2]), nil, type)
                t.equal(SMCValue.isNumeric(type), false, type)
            }
            for type in ["flt ", "ioft", "sp78", "fpe2", "ui8 ", "ui32", "si16", "flag"] {
                t.check(SMCValue.isNumeric(type), type)
            }
            t.equal(FourCC("TB0T")?.rawValue, 0x5442_3054)
            t.equal(FourCC("TB0T")?.description, "TB0T")
            t.equal(FourCC("flt ")?.description, "flt ")
            t.equal(FourCC("TOOLONG"), nil)
            t.equal(FourCC("T\u{e9}st"), nil, "ASCII only")
        }

        t.suite("App: sensors: SMC requests can only read") {
            // The allow-list: read a key, read the key at an index, read a key's info. Nothing else exists.
            t.equal(SMCCommand.allCases.map(\.rawValue).sorted(), [5, 8, 9])
            let key = FourCC("TB0T")!
            let read = SMCRequest(.readKey, key: key, dataSize: 4)
            t.equal(read.bytes.count, 80)
            t.equal(read.bytes[42], 5)
            t.equal(Array(read.bytes[0..<4]), [0x54, 0x30, 0x42, 0x54], "the key in host (little-endian) order")
            t.equal(Array(read.bytes[28..<32]), [4, 0, 0, 0], "data size")
            let byIndex = SMCRequest(.readKeyAtIndex, index: 300)
            t.equal(byIndex.bytes[42], 8)
            t.equal(Array(byIndex.bytes[44..<48]), [44, 1, 0, 0], "index 300 in data32")
            t.equal(SMCRequest(.readKeyInfo, key: key).bytes[42], 9)
            for command in SMCCommand.allCases {
                t.check(SMCBlock.isAllowed(SMCRequest(command, key: key).bytes), "\(command) may be sent")
            }
            // Any other command byte — 6 writes a key — is refused before anything is sent.
            for bad: UInt8 in [0, 1, 2, 3, 4, 6, 7, 10, 0x80, 0xff] {
                var block = read.bytes
                block[42] = bad
                t.check(!SMCBlock.isAllowed(block), "command \(bad) is refused")
            }
            t.check(!SMCBlock.isAllowed(Array(read.bytes.prefix(79))), "a block of another size is refused")
            t.check(!SMCBlock.isAllowed(read.bytes + [0]))
            // A reply: result, key, info and value.
            var reply = [UInt8](repeating: 0, count: 80)
            reply.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: key.rawValue, toByteOffset: 0, as: UInt32.self)
                raw.storeBytes(of: UInt32(4), toByteOffset: 28, as: UInt32.self)
                raw.storeBytes(of: FourCC("flt ")!.rawValue, toByteOffset: 32, as: UInt32.self)
                raw.storeBytes(of: Float(30.25).bitPattern, toByteOffset: 48, as: UInt32.self)
            }
            guard let parsed = SMCReply(reply) else { return t.check(false, "reply") }
            t.equal(parsed.result, 0)
            t.equal(parsed.key, key)
            t.equal(parsed.dataSize, 4)
            t.equal(parsed.dataType.description, "flt ")
            t.equal(SMCValue.decode(type: parsed.dataType.description, bytes: parsed.value(count: 4)), 30.25)
            t.equal(parsed.value(count: 99).count, 32, "at most 32 value bytes")
            reply[40] = SMCBlock.keyNotFound
            t.equal(SMCReply(reply)?.result, 0x84)
            t.equal(SMCReply(Array(reply.prefix(10))) == nil, true)
        }
    }

    // MARK: Classification

    /// Observed on an M4 Pro (values rounded): live keys, keys of a powered-down cluster (−4…5 °C), the 40.0
    /// placeholder, and keys the catalog does not use.
    static let m4Keys: [String: Double] = [
        "Tp00": 40.0, "Tp01": 52.3, "Tp05": 61.8, "Tp09": -4.0, "Tp0D": 1.5, "Tp2Q": 5.2, "Tp1i": 58.9, "Tpx1": 63.2,
        "Te04": 49.2, "Te05": 55.0, "Te06": 58.9, "Tex1": 131.0,
        "Tg04": 47.4, "Tg05": 53.8,
        "Ts00": 48.5, "Tsx1": 49.8, "Ts0P": 33.9, "Ts1P": 34.0,
        "TB0T": 34.5, "TB1T": 34.6, "TB2T": 34.1,
        "TH0a": 38.6, "TH0x": 38.9,
        "TG0B": 34.7, "TCMz": 79.1, "TaLP": 44.9, "Ta01": 8.3, "TVMR": 101.1, "TPD0": 50.7, "TW0P": 46.0,
    ]
    static let m4Cores: [CoreType] = Array(repeating: .efficiency, count: 4) + Array(repeating: .performance, count: 10)

    static func classificationTests(_ t: AppTestRunner) {
        t.suite("App: sensors: chip families and SMC key roles") {
            t.equal(ChipFamily.from(brand: "Apple M4 Pro", isAppleSilicon: true), .appleSilicon(generation: 4))
            t.equal(ChipFamily.from(brand: "Apple M1", isAppleSilicon: true), .appleSilicon(generation: 1))
            t.equal(ChipFamily.from(brand: "Apple M10 Ultra", isAppleSilicon: true), .appleSilicon(generation: 10))
            t.equal(ChipFamily.from(brand: "VirtualApple @ 2.50GHz", isAppleSilicon: true), .appleSilicon(generation: 0))
            t.equal(ChipFamily.from(brand: "Intel(R) Core(TM) i9-9980HK CPU @ 2.40GHz", isAppleSilicon: false), .intel)
            let m4 = ChipFamily.appleSilicon(generation: 4)
            func role(_ key: String, _ family: ChipFamily = m4) -> TemperatureRole? {
                SensorClassification.role(ofSMCKey: key, family: family)
            }
            t.equal(role("Tp01"), .cpuPerformance)
            t.equal(role("Te05"), .cpuEfficiency)
            t.equal(role("Tg0K"), .gpu)
            t.equal(role("Ts0A"), .soc)
            t.equal(role("Ts0P"), nil, "palm rest")
            t.equal(role("TB1T"), .battery)
            t.equal(role("TH0x"), .ssd)
            t.equal(role("TG0B"), nil, "Apple silicon: the battery gauge's own sensor")
            t.equal(role("TCMz"), nil)
            t.equal(role("Tf04"), nil, "Tf is not a core on M4")
            t.equal(role("Tp1"), nil, "four characters")
            t.equal(role("Xp01"), nil)
            t.equal(role("Tp01", .appleSilicon(generation: 1)), .cpu, "M1: one prefix for both clusters")
            t.equal(role("Tp09", .appleSilicon(generation: 2)), .cpu)
            t.equal(role("Tf04", .appleSilicon(generation: 3)), .cpuPerformance, "M3 performance cores")
            t.equal(role("Tf49", .appleSilicon(generation: 3)), .cpuPerformance)
            t.equal(role("Tf14", .appleSilicon(generation: 3)), .gpu, "M3 GPU")
            t.equal(role("Tp01", .appleSilicon(generation: 3)), nil)
            t.equal(role("Te05", .appleSilicon(generation: 3)), .cpuEfficiency)
            t.equal(role("Tp01", .appleSilicon(generation: 0)), .cpuPerformance, "unknown generation: newest rules")
            // Intel.
            t.equal(role("TC0P", .intel), .cpu)
            t.equal(role("TCXC", .intel), .cpu)
            t.equal(role("TC2C", .intel), .cpuCore(2))
            t.equal(role("TCGC", .intel), .gpu)
            t.equal(role("TCSA", .intel), .soc)
            t.equal(role("TG0P", .intel), .gpu)
            t.equal(role("TPCD", .intel), .soc)
            t.equal(role("TB0T", .intel), .battery)
            t.equal(role("TH0P", .intel), .ssd)
            t.equal(role("TA0P", .intel), nil, "ambient")
            t.equal(role("Tp01", .intel), nil)
            // Validity.
            func valid(_ v: Double, _ r: TemperatureRole = .cpuPerformance, _ f: ChipFamily = m4) -> Bool {
                SensorClassification.isValid(v, role: r, family: f)
            }
            t.check(valid(52.3))
            t.check(!valid(-4) && !valid(0) && !valid(5.2) && !valid(10), "a powered-down cluster")
            t.check(!valid(130) && !valid(.nan) && !valid(.infinity))
            t.check(!valid(40), "the 40.0 placeholder of Apple silicon CPU keys")
            t.check(valid(40.0625), "only exactly 40")
            t.check(valid(40, .gpu), "only CPU keys")
            t.check(valid(40, .cpu, .intel), "only Apple silicon")
            // HID names.
            t.equal(SensorClassification.role(ofHIDName: "pACC MTR Temp Sensor3"), .cpuPerformance)
            t.equal(SensorClassification.role(ofHIDName: "eACC MTR Temp Sensor0"), .cpuEfficiency)
            t.equal(SensorClassification.role(ofHIDName: "GPU MTR Temp Sensor1"), .gpu)
            t.equal(SensorClassification.role(ofHIDName: "SOC MTR Temp Sensor0"), .soc)
            t.equal(SensorClassification.role(ofHIDName: "PMU tdie4"), .soc)
            t.equal(SensorClassification.role(ofHIDName: "NAND CH0 temp"), .ssd)
            t.equal(SensorClassification.role(ofHIDName: "gas gauge battery"), .battery)
            t.equal(SensorClassification.role(ofHIDName: "PMU tdev1"), nil)
            t.equal(SensorClassification.role(ofHIDName: "PMU tcal"), nil)
        }

        t.suite("App: sensors: temperature catalogs of M-series and Intel Macs") {
            // M4 Pro.
            let m4 = SensorReadings.smcTemperatures(m4Keys, family: .appleSilicon(generation: 4), coreTypes: m4Cores,
                                                    physicalCores: 14)
            let v = m4.values
            t.equal(v["cpu"], 63.2, "the hottest valid CPU key (131 °C and the placeholders left out)")
            t.equal(v["cpu.performance"], 63.2)
            t.equal(v["cpu.efficiency"], 58.9)
            t.equal(v["cpu.core.1"], 58.9, "an efficiency core: its cluster")
            t.equal(v["cpu.core.14"], 63.2, "a performance core: its cluster")
            t.equal(v["cpu.core.15"], nil)
            t.equal(v["gpu"], 53.8)
            t.equal(v["soc"], 49.8)
            t.equal(v["battery"], 34.6)
            t.equal(v["ssd"], 38.9)
            t.equal(m4.infos.map(\.key), ["cpu", "cpu.performance", "cpu.efficiency"] + (1...14).map { "cpu.core.\($0)" }
                    + ["gpu", "soc", "battery", "ssd"], "catalog order")
            t.check(m4.infos.first?.source.hasPrefix("SMC ") == true)
            t.equal(m4.infos.first { $0.key == "soc" }?.label, "Chip temperature (SoC)")
            // A powered-down performance cluster: its entry stays, without a value.
            let idle = SensorReadings.smcTemperatures(["Tp09": -4, "Tp0D": 0, "Te04": 45], family: .appleSilicon(generation: 4),
                                                      coreTypes: m4Cores, physicalCores: 14)
            t.check(idle.infos.contains { $0.key == "cpu.performance" })
            t.equal(idle.values["cpu.performance"], nil)
            t.equal(idle.values["cpu"], 45)
            t.equal(idle.values["cpu.core.5"], nil, "a performance core of the powered-down cluster")
            // The GPU powered down (every Tg key reads −4…2.4 °C): the chip's temperature.
            var gated = m4Keys
            for key in ["Tg04", "Tg05"] { gated[key] = 2.4 }
            let gpuOff = SensorReadings.smcTemperatures(gated, family: .appleSilicon(generation: 4), coreTypes: m4Cores,
                                                        physicalCores: 14)
            t.equal(gpuOff.values["gpu"], 49.8, "a powered-down GPU is at the chip's temperature")
            t.equal(gpuOff.values["battery"], 34.6, "only the CPU clusters and the GPU")
            // M1: one prefix for both clusters.
            let m1 = SensorReadings.smcTemperatures(["Tp01": 45, "Tp05": 47, "Tp09": 41, "Tg05": 40, "TB0T": 30],
                                                    family: .appleSilicon(generation: 1),
                                                    coreTypes: [.efficiency, .efficiency, .performance, .performance],
                                                    physicalCores: 4)
            t.equal(m1.values["cpu"], 47)
            t.equal(m1.values["cpu.performance"], nil)
            t.equal(m1.values["cpu.efficiency"], nil)
            t.equal(m1.values["cpu.core.1"], 47, "the cluster is unknown: the hottest CPU sensor")
            t.equal(m1.values["gpu"], 40)
            // M3.
            let m3 = SensorReadings.smcTemperatures(["Te05": 44, "Tf04": 52, "Tf49": 55, "Tf14": 39, "Tf24": 41, "Tp01": 90],
                                                    family: .appleSilicon(generation: 3),
                                                    coreTypes: [.efficiency, .performance], physicalCores: 2)
            t.equal([m3.values["cpu"], m3.values["cpu.performance"], m3.values["cpu.efficiency"], m3.values["gpu"]],
                    [55, 55, 44, 41])
            // Intel: per-core keys, the package, the integrated GPU, the chipset.
            let intel = SensorReadings.smcTemperatures(["TC0P": 55, "TC0D": 60, "TC1C": 58, "TC2C": 62, "TC3C": 0,
                                                        "TCGC": 50, "TCSA": 57, "TG0P": 48, "TPCD": 52, "TB0T": 30,
                                                        "TH0P": 36, "TA0P": 25, "Ts0P": 31],
                                                       family: .intel, coreTypes: [], physicalCores: 4)
            let iv = intel.values
            t.equal(iv["cpu"], 62)
            t.equal((1...4).map { iv["cpu.core.\($0)"] }, [62, 58, 62, 62], "own sensor, else the package")
            t.equal(iv["cpu.core.5"], nil, "physical cores only")
            t.equal(iv["cpu.performance"], nil)
            t.equal([iv["gpu"], iv["soc"], iv["battery"], iv["ssd"]], [50, 57, 30, 36])
            t.equal(intel.infos.first { $0.key == "soc" }?.label, "Chipset temperature (PCH)")
            // HID (an M1 names its cluster sensors).
            let hid = SensorReadings.hidTemperatures(
                [("pACC MTR Temp Sensor2", 45.1), ("pACC MTR Temp Sensor3", 46.0), ("eACC MTR Temp Sensor0", 40.2),
                 ("GPU MTR Temp Sensor1", 38), ("SOC MTR Temp Sensor0", 42), ("PMU tdie1", 44), ("PMU tdev1", -92.01),
                 ("NAND CH0 temp", 35), ("gas gauge battery", 31)],
                family: .appleSilicon(generation: 1), coreTypes: [.efficiency, .performance], physicalCores: 2)
            t.equal([hid.values["cpu.performance"], hid.values["cpu.efficiency"], hid.values["cpu.core.1"],
                     hid.values["cpu.core.2"], hid.values["gpu"], hid.values["soc"], hid.values["ssd"], hid.values["battery"]],
                    [46, 40.2, 40.2, 46, 38, 44, 35, 31])
            t.check(hid.infos.first?.source.hasPrefix("HID") == true)
            // Nothing classifiable: an empty group.
            let none = SensorReadings.smcTemperatures(["TaLP": 40], family: .appleSilicon(generation: 4), coreTypes: m4Cores,
                                                      physicalCores: 14)
            t.equal(none.infos.count, 0)
            // The temperature keys of a key list: numeric T keys with a role.
            let keys = SensorReadings.temperatureKeys(["Tp01": SMCKeyInfo(size: 4, type: "flt "),
                                                       "Tp02": SMCKeyInfo(size: 4, type: "hex_"),
                                                       "TaLP": SMCKeyInfo(size: 4, type: "flt "),
                                                       "TB0T": SMCKeyInfo(size: 4, type: "flt "),
                                                       "Te04": SMCKeyInfo(size: 8, type: "ioft")],
                                                      family: .appleSilicon(generation: 4))
            t.equal(keys, ["TB0T", "Te04", "Tp01"])
        }
    }

    // MARK: Fans, power, GPU, battery

    static func dictionaryTests(_ t: AppTestRunner) {
        t.suite("App: sensors: fans, power, GPU and battery readings") {
            // Fans: FNum = 2 (floats in RPM on Apple silicon).
            let smc: [String: Double] = ["FNum": 2, "F0Ac": 2296.5, "F0Mn": 2317, "F0Mx": 7826, "F0Tg": 2317,
                                         "F1Ac": 0, "F1Mn": 2317, "F1Mx": 7826, "F1Tg": 0, "PSTR": 27.03, "PDTR": 0]
            let fans = SensorReadings.fans { smc[$0] }
            t.equal(fans.infos.map(\.key), ["fan.1", "fan.1.min", "fan.1.max", "fan.1.target", "fan.2", "fan.2.min",
                                            "fan.2.max", "fan.2.target"])
            t.equal(fans.values["fan.1"], 2296.5)
            t.equal(fans.values["fan.2"], 0, "a stopped fan reads 0")
            t.equal(fans.infos.first?.minimum, 2317)
            t.equal(fans.infos.first?.maximum, 7826)
            t.equal(SensorReadings.fans { ["FNum": 0.0][$0] }.infos.count, 0, "fanless")
            t.equal(SensorReadings.fans { _ in nil }.infos.count, 0, "no FNum")
            t.equal(SensorReadings.fans { ["FNum": 1.0, "F0Ac": 99_999.0][$0] }.infos.count, 0, "not a speed")
            t.equal(SensorReadings.fans { ["FNum": 99.0, "F0Ac": 1200.0][$0] }.infos.count, 1, "at most 16, and only fans that exist")
            let power = SensorReadings.systemPower { smc[$0] }
            t.equal(power.values, ["power.system": 27.03, "power.adapter": 0])
            t.equal(SensorReadings.systemPower { ["PSTR": -3.0][$0] }.values, [:])
            // GPU statistics: Apple silicon (AGX), the extra entry Rosetta adds (no statistics), an AMD card.
            let agx: [String: Any] = ["Device Utilization %": 24, "Renderer Utilization %": 23, "Tiler Utilization %": 12,
                                      "In use system memory": 716_996_608, "Alloc system memory": 3_727_327_232]
            let gpu = SensorReadings.gpu([["SplitSceneCount": 0], agx])
            t.equal(gpu.values["gpu.usage"], 24)
            t.equal(gpu.values["gpu.usage.renderer"], 23)
            t.equal(gpu.values["gpu.usage.tiler"], 12)
            t.equal(gpu.values["gpu.memory"], 716_996_608)
            t.equal(gpu.values["gpu"], nil, "no GPU temperature from Apple silicon statistics")
            let amd: [String: Any] = ["Device Utilization %": 7, "Temperature(C)": 61, "Fan Speed(%)": 33,
                                      "Core Clock(MHz)": 1300, "Memory Clock(MHz)": 1500, "vramUsedBytes": 1_073_741_824]
            let intelGPU: [String: Any] = ["Device Utilization %": 55, "In use system memory": 100]
            let both = SensorReadings.gpu([intelGPU, amd])
            t.equal(both.values["gpu.usage"], 55, "the busiest GPU")
            t.equal(both.values["gpu.memory"], 1_073_741_924, "added up")
            t.equal(both.values["gpu"], 61)
            t.equal(both.values["gpu.fan"], 33)
            t.equal(both.values["frequency.gpu"], 1300)
            t.equal(both.values["frequency.gpu.memory"], 1500)
            t.equal(SensorReadings.gpu([]).infos.count, 0)
            t.equal(SensorReadings.gpu([["Device Utilization %": 250]]).values["gpu.usage"], 100, "clamped")
            // Battery (Apple silicon: MaxCapacity is a percentage; the raw capacity is AppleRawMaxCapacity).
            let battery: [String: Any] = ["DesignCapacity": 6249, "AppleRawMaxCapacity": 5641, "MaxCapacity": 100,
                                          "CycleCount": 223, "DesignCycleCount9C": 1000, "Voltage": 11891,
                                          "Amperage": NSNumber(value: UInt64(bitPattern: -1465)),
                                          "Temperature": 3077]
            let b = SensorReadings.battery(battery)
            t.close(b.values["battery.health"] ?? 0, 5641.0 / 6249 * 100, accuracy: 1e-9)
            t.equal(b.values["battery.cycles"], 223)
            t.equal(b.infos.first { $0.key == "battery.cycles" }?.maximum, 1000)
            t.close(b.values["battery.voltage"] ?? 0, 11.891, accuracy: 1e-9)
            t.close(b.values["battery.current"] ?? 0, -1.465, accuracy: 1e-9, "negative: discharging")
            t.close(b.values["battery"] ?? 0, 30.77, accuracy: 1e-9)
            // Intel: MaxCapacity is in mAh.
            let intelBattery = SensorReadings.battery(["DesignCapacity": 5000, "MaxCapacity": 4500, "Amperage": 1200])
            t.close(intelBattery.values["battery.health"] ?? 0, 90, accuracy: 1e-9)
            t.close(intelBattery.values["battery.current"] ?? 0, 1.2, accuracy: 1e-9, "charging")
            t.equal(SensorReadings.battery(["MaxCapacity": 100, "DesignCapacity": 6000]).values["battery.health"], nil,
                    "a percentage is not a capacity")
            t.equal(SensorReadings.battery([:]).infos.count, 0)
        }
    }

    // MARK: IOReport

    /// `voltage-states…` data: pairs of little-endian 32-bit words.
    static func table(_ pairs: [(UInt32, UInt32)]) -> Data {
        var data = Data()
        for (a, b) in pairs {
            withUnsafeBytes(of: a.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: b.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// M4-like tables, shortened: the `-sram` tables hold the CPU clocks in kHz, the base tables the core voltages; the
    /// GPU table is in Hz with an "off" entry first.
    static let tables: [String: Data] = [
        "voltage-states1": table([(64250, 600), (46678, 650), (36653, 715), (31030, 770), (27863, 840), (25883, 910),
                                  (25283, 910)]),
        "voltage-states1-sram": table([(1_020_000, 790), (1_404_000, 800), (1_788_000, 830), (2_112_000, 860),
                                       (2_352_000, 900), (2_532_000, 940), (2_592_000, 940)]),
        "voltage-states5": table([(52012, 650), (30000, 800), (14524, 1180)]),
        "voltage-states5-sram": table([(1_260_000, 790), (3_000_000, 900), (4_512_000, 1080)]),
        "voltage-states9": table([(0, 125), (338_000_000, 600), (1_578_000_000, 1030)]),
    ]

    static func channel(_ name: String, _ states: [(String, Int64)]) -> DVFSResidency {
        DVFSResidency(name: name, states: states.map { (name: $0.0, residency: $0.1) })
    }

    /// Two efficiency cores (one ran at its lowest and highest clock, one did not run) and two performance cores.
    static func fixtureCores() -> [DVFSResidency] {
        let eStates = ["V0P6", "V1P5", "V2P4", "V3P3", "V4P2", "V5P1", "V6P0"]
        var running: [(String, Int64)] = [("DOWN", 0), ("IDLE", 500)]
        for (i, name) in eStates.enumerated() { running.append((name, i == 0 || i == 6 ? 100 : 0)) }
        var resting: [(String, Int64)] = [("DOWN", 900), ("IDLE", 100)]
        for name in eStates { resting.append((name, 0)) }
        return [channel("ECPU000", running), channel("ECPU010", resting),
                channel("PCPU000", [("IDLE", 0), ("V0", 0), ("V1", 300), ("V2", 100)]),
                channel("PCPU010", [("IDLE", 1000), ("V0", 0), ("V1", 0), ("V2", 0)])]
    }

    static func ioReportTests(_ t: AppTestRunner) {
        t.suite("App: sensors: IOReport clock tables and residencies") {
            let gpuTable = DVFSTable.parse(tables["voltage-states9"]!)
            t.equal(gpuTable?.frequencies, [338, 1578], "Hz → MHz, the off entry dropped")
            t.equal(DVFSTable.parse(tables["voltage-states1-sram"]!)?.frequencies.first, 1020, "kHz → MHz")
            t.equal(DVFSTable.parse(Data([1, 2, 3])) == nil, true)
            let e = DVFSTable.table(for: .efficiency, states: 7, properties: tables)
            t.equal(e?.frequencies, [1020, 1404, 1788, 2112, 2352, 2532, 2592], "clocks from the -sram table")
            t.equal(e?.voltages?.first, 0.6, "core voltages from the base table")
            t.equal(DVFSTable.table(for: .efficiency, states: 6, properties: tables), nil, "the state count must match")
            let p = DVFSTable.table(for: .performance, states: 3, properties: tables)
            t.equal(p?.frequencies, [1260, 3000, 4512])
            t.equal(DVFSTable.table(for: .gpu, states: 2, properties: tables)?.frequencies, [338, 1578])
            // Another table number when the usual one does not fit.
            var moved = tables
            moved["voltage-states13-sram"] = moved["voltage-states5-sram"]
            moved["voltage-states13"] = moved["voltage-states5"]
            moved["voltage-states5-sram"] = table([(1, 1)])
            moved["voltage-states5"] = nil
            t.equal(DVFSTable.table(for: .performance, states: 3, properties: moved)?.frequencies, [1260, 3000, 4512])

            // Residencies (arbitrary units): two efficiency and two performance cores, the GPU.
            let cores = fixtureCores()
            let gpu = [channel("GPUPH", [("OFF", 500), ("P1", 250), ("P2", 250)])]
            let e0 = IOReportMath.average([cores[0]], table: e!)
            let e0Expected: Double = (100 * 1020 + 100 * 2592) / 200
            t.close(e0?.mhz ?? 0, e0Expected)
            t.equal(IOReportMath.average([cores[1]], table: e!)?.mhz, 1020, "a core that did not run: its lowest clock")
            t.equal(IOReportMath.average([cores[1]], table: e!)?.volts == nil, true)
            t.equal(IOReportMath.average([cores[2]], table: e!) == nil, true, "states that do not match the table")
            // Energy.
            t.equal(IOReportMath.joules(4500, unit: "mJ"), 4.5)
            t.equal(IOReportMath.joules(2_000_000, unit: "uJ"), 2)
            t.equal(IOReportMath.joules(3_000_000_000, unit: "nJ"), 3)
            t.equal(IOReportMath.joules(1, unit: "kWh") == nil, true)
            t.equal(IOReportMath.power(["CPU Energy": 4.5, "GPU": 1, "GPU Energy": 1.25, "ANE": 0, "DRAM": 0.5,
                                        "AMCC": 9], seconds: 0.5),
                    ["power.cpu": 9, "power.gpu": 2.5, "power.ane": 0, "power.dram": 1], "GPU Energy is preferred")
            t.equal(IOReportMath.power(["ANE0": 1, "ANE1": 2, "ANEX": 5], seconds: 1), ["power.ane": 3])
            t.equal(IOReportMath.power(["CPU Energy": 1], seconds: 0), [:])
            // Core channels: each cluster type's channels, in name order, to its cores in logical order.
            let types: [CoreType] = [.efficiency, .efficiency, .performance, .performance]
            t.equal(IOReportMath.coreChannels(names: ["PCPU010", "ECPU010", "PCPU000", "ECPU000"], coreTypes: types),
                    [0: "ECPU000", 1: "ECPU010", 2: "PCPU000", 3: "PCPU010"])
            t.equal(IOReportMath.coreChannels(names: ["ECPU000", "PCPU000"], coreTypes: types), [:], "counts must match")
            // A whole reading.
            let r = IOReportMath.reading(joules: ["CPU Energy": 4.5, "GPU Energy": 1.25, "ANE": 0, "DRAM": 0.5],
                                         seconds: 1, cores: cores, gpu: gpu, coreTypes: types, tables: tables)
            let v = r.values
            t.equal(v["power.cpu"], 4.5)
            t.close(v["frequency.cpu.1"] ?? 0, 1806)
            t.equal(v["frequency.cpu.2"], 1020)
            let p0Expected: Double = (300 * 3000 + 100 * 4512) / 400
            t.close(v["frequency.cpu.3"] ?? 0, p0Expected)
            t.equal(v["frequency.cpu.4"], 1260)
            t.close(v["frequency.cpu.efficiency"] ?? 0, 1806)
            t.close(v["frequency.cpu.performance"] ?? 0, 3378)
            t.close(v["frequency.cpu"] ?? 0, 3378, "the faster cluster")
            let gpuExpected: Double = (250 * 338 + 250 * 1578) / 500
            t.close(v["frequency.gpu"] ?? 0, gpuExpected)
            let voltsE: Double = 100 * 0.6 + 100 * 0.91
            let voltsP: Double = 300 * 0.8 + 100 * 1.18
            t.close(v["voltage.cpu"] ?? 0, (voltsE + voltsP) / 600, accuracy: 1e-9)
            t.equal(r.infos.first { $0.key == "frequency.cpu.performance" }?.maximum, 4512)
            t.equal(r.infos.first { $0.key == "frequency.cpu" }?.minimum, 1020)
            t.equal(r.infos.map(\.key), ["power.cpu", "power.gpu", "power.ane", "power.dram", "frequency.cpu",
                                         "frequency.cpu.performance", "frequency.cpu.efficiency", "frequency.cpu.1",
                                         "frequency.cpu.2", "frequency.cpu.3", "frequency.cpu.4", "frequency.gpu",
                                         "voltage.cpu"])
            // No tables (another chip's layout): power only.
            let bare = IOReportMath.reading(joules: ["CPU Energy": 1], seconds: 1, cores: cores, gpu: gpu, coreTypes: types,
                                            tables: [:])
            t.equal(bare.infos.map(\.key), ["power.cpu"])
            t.equal(SensorGroupReading.coreType(clusterType: Data("E\0".utf8)), .efficiency)
            t.equal(SensorGroupReading.coreType(clusterType: Data("P".utf8)), .performance)
            t.equal(SensorGroupReading.coreType(clusterType: Data()), nil)
        }
    }

    // MARK: Catalog

    static func catalogTests(_ t: AppTestRunner) {
        t.suite("App: sensors: catalog order, key groups and the kept key list") {
            let keys = ["fan.2.max", "cpu.core.10", "power.system", "cpu", "fan.1", "cpu.core.2", "fan.2", "fan.1.target",
                        "gpu", "frequency.cpu.3", "frequency.cpu", "battery.cycles", "gpu.usage", "voltage.cpu"]
            t.equal(keys.sorted { SensorGroupReading.order($0) < SensorGroupReading.order($1) },
                    ["cpu", "cpu.core.2", "cpu.core.10", "gpu", "fan.1", "fan.1.target", "fan.2", "fan.2.max",
                     "power.system", "frequency.cpu", "frequency.cpu.3", "voltage.cpu", "gpu.usage", "battery.cycles"])
            t.equal(SensorGroup.groups(for: "cpu"), [.temperatures])
            t.equal(SensorGroup.groups(for: "cpu.core.3"), [.temperatures])
            t.equal(SensorGroup.groups(for: "gpu"), [.temperatures, .gpu])
            t.equal(SensorGroup.groups(for: "battery"), [.temperatures, .battery])
            t.equal(SensorGroup.groups(for: "fan.2.min"), [.fans])
            t.equal(SensorGroup.groups(for: "power.system"), [.systemPower])
            t.equal(SensorGroup.groups(for: "power.cpu"), [.ioReport])
            t.equal(SensorGroup.groups(for: "frequency.cpu.4"), [.ioReport])
            t.equal(SensorGroup.groups(for: "frequency.gpu"), [.ioReport, .gpu])
            t.equal(SensorGroup.groups(for: "frequency.gpu.memory"), [.gpu])
            t.equal(SensorGroup.groups(for: "voltage.cpu"), [.ioReport])
            t.equal(SensorGroup.groups(for: "gpu.memory"), [.gpu])
            t.equal(SensorGroup.groups(for: "battery.health"), [.battery])
            t.equal(SensorGroup.groups(for: "warp.core"), [])
            for entry in SensorKeys.common {
                t.check(!SensorGroup.groups(for: entry.key).isEmpty, "\(entry.key) has a group")
            }
            // The SMC key list is kept per model and macOS build.
            let url = t.temporaryDirectory("sensors").appendingPathComponent("Sensors/smc-keys.json")
            let list = SMCKeyList(model: "Mac16,8", build: "25F84", keys: ["TB0T": SMCKeyInfo(size: 4, type: "flt ")])
            list.save(url)
            t.equal(SMCKeyList.load(url), list)
            try? Data("{\"version\":2}".utf8).write(to: url)
            t.equal(SMCKeyList.load(url), nil, "another format")
            t.equal(SMCKeyList.load(url.deletingLastPathComponent().appendingPathComponent("none.json")), nil)
        }
    }

    // MARK: Service

    /// Readings by group; counts reads, releases and whether two reads ever overlapped.
    final class FakeHardware: SensorHardware {
        private let lock = NSLock()
        private var readings: [SensorGroup: SensorGroupReading] = [:]
        private var inside = 0
        private(set) var overlapped = false
        private(set) var reads: [Set<SensorGroup>] = []
        private(set) var released: [Set<SensorGroup>] = []
        var delay: TimeInterval = 0
        var tjMax: Double { 110 }

        func set(_ group: SensorGroup, _ values: [(SensorInfo, Double?)]) {
            var reading = SensorGroupReading()
            for (info, value) in values { reading.add(info, value) }
            lock.lock()
            readings[group] = reading
            lock.unlock()
        }

        func read(_ groups: Set<SensorGroup>, now: TimeInterval) -> [SensorGroup: SensorGroupReading] {
            lock.lock()
            inside += 1
            if inside > 1 { overlapped = true }
            if reads.count < 100_000 { reads.append(groups) }
            let out = readings.filter { groups.contains($0.key) }
            lock.unlock()
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            lock.lock()
            inside -= 1
            lock.unlock()
            return out
        }

        func release(_ groups: Set<SensorGroup>) {
            lock.lock()
            if !groups.isEmpty, released.count < 100_000 { released.append(groups) }
            lock.unlock()
        }

        var readCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads.count
        }

        var lastRead: Set<SensorGroup>? {
            lock.lock()
            defer { lock.unlock() }
            return reads.last
        }

        var lastReleased: Set<SensorGroup>? {
            lock.lock()
            defer { lock.unlock() }
            return released.last
        }
    }

    static func info(_ key: String, _ kind: SensorKind = .temperature, min: Double? = nil, max: Double? = nil) -> SensorInfo {
        SensorInfo(key: key, label: key, kind: kind, minimum: min, maximum: max, source: "fake")
    }

    static func serviceTests(_ t: AppTestRunner) {
        t.suite("App: sensors: the service reads what skins ask for, in the background") {
            let hardware = FakeHardware()
            hardware.set(.temperatures, [(info("cpu"), 50), (info("cpu.core.1"), 48), (info("gpu"), 40)])
            hardware.set(.fans, [(info("fan.1", .fan, min: 1200, max: 6000), 2000)])
            hardware.set(.gpu, [(info("gpu.usage", .percent), 12)])
            let clock = Guarded(1000.0)
            let service = SensorService(hardware: hardware, clock: { clock.current })
            /// Runs `body` (which asks for something stale or new) and waits until the refreshes it started ended.
            func afterRefresh(_ body: () -> Void) {
                let before = service.refreshCount
                body()
                t.check(AppSelfTest.spin(timeout: 30) { service.refreshCount > before && !service.isRefreshing },
                        "a refresh ran")
            }
            afterRefresh {
                t.equal(service.value("cpu"), nil, "nothing read yet")
                t.check(service.isPending("cpu"))
            }
            t.equal(service.refreshCount, 1, "one refresh")
            t.equal(hardware.lastRead, [.temperatures], "only the group asked for")
            t.equal(service.value("cpu"), 50)
            t.equal(service.isPending("cpu"), false)
            t.equal(service.value("cpu.core.1"), 48)
            t.equal(service.refreshCount, 1, "fresh readings are answered from memory")
            t.equal(service.list().map(\.key), ["cpu", "cpu.core.1", "gpu"])
            t.equal(service.info("gpu")?.label, "gpu")
            t.equal(service.tjMax(), 110, "a CPU temperature exists")
            t.equal(service.value("warp.core"), nil)
            t.equal(service.isPending("warp.core"), false, "not a sensor: never pending")
            // Stale after 0.9 s: the last reading is answered while a new one is taken.
            hardware.set(.temperatures, [(info("cpu"), 55), (info("cpu.core.1"), 48), (info("gpu"), 40)])
            clock.access { $0 += 1 }
            afterRefresh { t.equal(service.value("cpu"), 50) }
            t.equal(service.value("cpu"), 55)
            // "gpu": the temperatures answer; the GPU statistics are read too (never read yet: a refresh at once).
            afterRefresh {
                t.equal(service.value("gpu"), 40)
                t.check(service.isPending("gpu"), "until the GPU statistics were read once")
            }
            t.equal(service.isPending("gpu"), false)
            clock.access { $0 += 1 }
            afterRefresh { _ = service.value("fan.1") }
            t.equal(hardware.lastRead, [.temperatures, .gpu, .fans], "every wanted group in one pass")
            t.equal(service.value("fan.1"), 2000)
            t.equal(service.info("fan.1")?.maximum, 6000)
            // A group asked for while a refresh runs is read right after it.
            hardware.delay = 0.2
            clock.access { $0 += 1 }
            afterRefresh {
                _ = service.value("cpu")
                Thread.sleep(forTimeInterval: 0.05)
                t.equal(service.value("battery.cycles"), nil)
            }
            hardware.delay = 0
            t.check(hardware.lastRead?.contains(.battery) == true, "the battery was read after all")
            t.equal(service.isPending("battery.cycles"), false)
            // A value missing from a new reading keeps its last value for up to 10 s.
            hardware.set(.temperatures, [(info("cpu"), nil), (info("cpu.core.1"), 49)])
            clock.access { $0 += 1 }
            afterRefresh { _ = service.value("cpu") }
            t.equal(service.value("cpu"), 55, "held")
            t.equal(service.value("gpu"), nil, "gone from the list: not held")
            clock.access { $0 += 11 }
            afterRefresh { _ = service.value("cpu") }
            t.equal(service.value("cpu"), nil, "no longer held")
            // Groups nobody asked for in 30 s are let go.
            clock.access { $0 += 31 }
            afterRefresh { _ = service.value("cpu.core.1") }
            t.equal(hardware.lastRead, [.temperatures])
            t.check(hardware.lastReleased?.contains(.fans) == true, "the fans' hardware is let go")
            t.check(service.isPending("fan.1"), "and their reading dropped")
            afterRefresh { t.equal(service.value("fan.1"), nil) }
            // Everything: waits until every group was read, then answers once.
            let lists = Collected<[SensorInfo]>()
            service.discover { lists.add($0) }
            service.discover { lists.add($0) }
            t.check(AppSelfTest.spin(timeout: 30) { lists.count == 2 }, "both callers are answered")
            t.equal(hardware.lastRead, Set(SensorGroup.allCases), "every group")
            t.equal(lists.all.first?.map(\.key), ["cpu", "cpu.core.1", "fan.1", "gpu.usage"])
            t.equal(service.readAll().count, 4, "the report's synchronous read")
            t.check(!hardware.overlapped, "one read at a time")
            // Without a CPU temperature there is no TjMax.
            let empty = SensorService(hardware: FakeHardware(), clock: { clock.current })
            t.equal(empty.readAll().count, 0)
            t.equal(empty.tjMax(), nil)
        }
    }

    // MARK: Threads

    static func threadingTests(_ t: AppTestRunner) {
        t.suite("App: skin threading: the sensor service answers several threads at once") {
            // Every reading stale at every look (the clock runs ahead at each one), and a slow hardware read: the
            // threads keep claiming refreshes, asking, listing and discovering while one read runs.
            let hardware = FakeHardware()
            hardware.delay = 0.001
            hardware.set(.temperatures, [(info("cpu"), 50), (info("gpu"), 40)])
            hardware.set(.fans, [(info("fan.1", .fan), 2000)])
            hardware.set(.ioReport, [(info("power.cpu", .power), 4)])
            hardware.set(.battery, [(info("battery.cycles", .count), 223)])
            let time = Guarded(0.0)
            let service = SensorService(hardware: hardware, clock: { time.access { now -> TimeInterval in
                now += 0.25
                return now
            } })
            let keys = ["cpu", "gpu", "fan.1", "power.cpu", "battery.cycles", "cpu.core.1", "power.system", "bogus"]
            let expected: [String: Double] = ["cpu": 50, "gpu": 40, "fan.1": 2000, "power.cpu": 4, "battery.cycles": 223]
            let problems = Collected<String>()
            let answered = Collected<Int>()
            let asked = Collected<Int>()
            let finished = ServiceThreadingSelfTests.onThreads(8) { i in
                for round in 0..<2000 {
                    // Now and then a pause, as between a skin's updates: refreshes finish and new ones are claimed.
                    if round % 100 == 99 { usleep(500) }
                    let key = keys[(round + i) % keys.count]
                    if let v = service.value(key), v != expected[key] { problems.add("\(key) = \(v)") }
                    _ = service.isPending(key)
                    _ = service.info(key)
                    if service.list().count > 5 { problems.add("list") }
                    if round % 250 == i {
                        asked.add(1)
                        service.discover { list in
                            if list.count > 5 { problems.add("discovered \(list.count)") }
                            answered.add(1)
                        }
                    }
                }
            }
            t.check(finished, "the threads finish")
            t.check(AppSelfTest.spin(timeout: 60) { answered.count == asked.count }, "every discovery is answered")
            t.equal(Set(problems.all).sorted(), [], "every answer is a reading of the hardware")
            t.check(!hardware.overlapped, "the hardware is read by one thread at a time")
            t.check(hardware.readCount > 1, "refreshes ran: \(hardware.readCount), \(service.refreshCount)")
            // After the storm nothing runs while nobody asks (no refresh keeps claiming another).
            RenderCommand.wait(milliseconds: 300)
            let before = service.refreshCount
            RenderCommand.wait(milliseconds: 300)
            t.equal(service.refreshCount, before, "idle")
        }
    }

    // MARK: Wiring

    static func wiringTests(_ t: AppTestRunner) {
        t.suite("App: sensors: skins read them through SystemMonitor") {
            let hardware = FakeHardware()
            hardware.set(.temperatures, [(info("cpu"), 61.5), (info("cpu.core.1"), 48), (info("cpu.core.2"), 61.5),
                                         (info("gpu"), 44)])
            hardware.set(.fans, [(info("fan.1", .fan, min: 2317, max: 7826), 2400)])
            hardware.set(.gpu, [(info("gpu.usage", .percent), 24), (info("gpu.memory", .bytes), 104_857_600)])
            let monitor = SystemMonitor(sensors: SensorService(hardware: hardware))
            let folder = t.temporaryDirectory("sensor-skin")
            let config = folder.appendingPathComponent("Sensors", isDirectory: true)
            try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
            let file = config.appendingPathComponent("Sensors.ini")
            try """
            [Rainmeter]
            Update=1000
            [Max]
            Measure=Plugin
            Plugin=CoreTemp
            [TjMax]
            Measure=Plugin
            Plugin=CoreTemp
            CoreTempType=TjMax
            [Core]
            Measure=Plugin
            Plugin=CoreTemp
            CoreTempType=Temperature
            CoreTempIndex=1
            [Fan]
            Measure=Plugin
            Plugin=MacSensors
            Sensor=fan.1
            [GPU]
            Measure=Plugin
            Plugin=UsageMonitor
            Alias=GPU
            [SpeedFan]
            Measure=Plugin
            Plugin=SpeedFanPlugin
            SpeedFanNumber=1
            [VRAM]
            Measure=Plugin
            Plugin=MSIAfterburner
            DataSource=Memory usage
            [T]
            Meter=String
            MeasureName=Fan
            """.write(to: file, atomically: true, encoding: .utf8)
            let host = RenderHost()
            let skin = Skin(config: "Sensors", fileURL: file, skinsDirectory: folder, system: monitor, host: host)
            try skin.load()
            skin.update()
            t.equal(skin.measure(named: "Max")?.value, 0, "the first update asks; the readings come later")
            t.check(!host.logs.contains { $0.contains("reports no") || $0.contains("has no sensor") }, "pending: no notes")
            t.check(AppSelfTest.spin(timeout: 30) { !monitor.sensorPending("gpu.usage") && !monitor.sensorPending("cpu")
                && !monitor.sensorPending("fan.1") }, "read in the background")
            skin.update()
            t.equal(skin.measure(named: "Max")?.value, 61.5)
            t.equal(skin.measure(named: "TjMax")?.value, 110)
            t.equal(skin.measure(named: "Core")?.value, 61.5)
            t.equal(skin.measure(named: "Fan")?.value, 2400)
            t.equal(skin.measure(named: "Fan")?.minValue, 2317)
            t.equal(skin.measure(named: "Fan")?.stringValue, "2400 RPM")
            t.equal(skin.measure(named: "GPU")?.value, 24)
            t.equal(skin.measure(named: "SpeedFan")?.value, 44, "SpeedFan temperature 1 = gpu")
            t.equal(skin.measure(named: "VRAM")?.value, 100)
            withExtendedLifetime(host) {}
        }
    }

    // MARK: Live

    static func liveTests(_ t: AppTestRunner) {
        t.suite("App: sensors: this Mac's sensors are absent or plausible (live)") {
            // A service of its own (nothing kept on disk), read off the main thread with a time limit: a virtual
            // machine has no sensors, and a hanging read must fail the test rather than the whole run.
            let service = SensorService(hardware: LiveSensorHardware(keyCacheURL: { nil }))
            let result = Collected<[(SensorInfo, Double?)]>()
            let thread = Thread {
                let list = service.readAll()
                result.add(list.map { ($0, service.value($0.key)) })
            }
            thread.stackSize = 8 << 20
            thread.start()
            guard AppSelfTest.spin(timeout: 120, until: { result.count == 1 }), let readings = result.all.first else {
                return t.check(false, "the sensors are read within two minutes")
            }
            print("    \(readings.count) sensors, \(readings.filter { $0.1 != nil }.count) with readings")
            for (info, value) in readings {
                t.equal(SensorKeys.kind(of: info.key), info.kind, "\(info.key) is a catalog key of its kind")
                t.check(!info.label.isEmpty && !info.source.isEmpty, "\(info.key) is described")
                guard let v = value else { continue }
                let plausible: ClosedRange<Double>
                switch info.kind {
                case .temperature: plausible = 10...130
                case .fan: plausible = 0...20_000
                case .power: plausible = 0...5_000
                case .frequency: plausible = 0...10_000
                case .percent: plausible = 0...150
                case .count: plausible = 0...100_000
                case .voltage: plausible = 0...100
                case .current: plausible = -100...100
                case .bytes: plausible = 0...1e15
                }
                t.check(plausible.contains(v), "\(info.key) = \(v) is plausible")
            }
            t.equal(Set(readings.map(\.0.key)).count, readings.count, "each key once")
        }
    }
}
