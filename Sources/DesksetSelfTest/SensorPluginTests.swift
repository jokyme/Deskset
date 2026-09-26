import Foundation
@testable import DesksetCore

// Hardware sensor plugins over the sensor catalog (suite prefix "Plugin: sensors"): the catalog's keys, the
// HardwareSensorSource defaults, and every mapping of CoreTemp, SpeedFan, UsageMonitor / PerfMon, MSIAfterburner and
// MacSensors onto catalog keys. The sensors are a fake system data source that is also a sensor source (as the app's
// SystemMonitor is), so the tests never need real sensors.

/// A system data source with a sensor catalog: `values` by catalog key, `pending` keys not read yet.
private final class CatalogSystem: FakeSystem, HardwareSensorSource {
    var infos: [SensorInfo] = []
    var values: [String: Double] = [:]
    var pending: Set<String> = []
    var tjMax: Double? = 110
    var asked: [String] = []

    func sensorList() -> [SensorInfo] { infos }
    func sensorValue(_ key: String) -> Double? {
        asked.append(key)
        return values[key]
    }
    func sensorPending(_ key: String) -> Bool { pending.contains(key) }
    func cpuTjMax() -> Double? { tjMax }

    /// An M-series-like Mac: two clusters, 4 cores, 2 fans, power, clocks, GPU and battery.
    static func mac() -> CatalogSystem {
        let s = CatalogSystem()
        s.values = [
            "cpu": 61.5, "cpu.performance": 61.5, "cpu.efficiency": 48, "gpu": 44, "battery": 31, "ssd": 38,
            "cpu.core.1": 48, "cpu.core.2": 48, "cpu.core.3": 61.5, "cpu.core.4": 61.5,
            "fan.1": 2300, "fan.1.min": 2317, "fan.1.max": 7826, "fan.1.target": 2317,
            "fan.2": 3913, "fan.2.min": 2317, "fan.2.max": 7826,
            "power.system": 18.25, "power.cpu": 4.5, "power.gpu": 1.25, "power.ane": 0, "power.dram": 0.5,
            "frequency.cpu": 3504, "frequency.cpu.performance": 3504, "frequency.cpu.efficiency": 1968,
            "frequency.cpu.1": 1968, "frequency.cpu.2": 1020, "frequency.cpu.3": 3504, "frequency.cpu.4": 4512,
            "frequency.gpu": 338, "voltage.cpu": 0.85,
            "gpu.usage": 24, "gpu.memory": 716_996_608,
            "battery.health": 90.3, "battery.cycles": 223, "battery.voltage": 11.891, "battery.current": -1.465,
        ]
        s.infos = [
            SensorInfo(key: "cpu", label: "CPU temperature (hottest sensor)", kind: .temperature),
            SensorInfo(key: "fan.1", label: "Fan 1 speed", kind: .fan, minimum: 2317, maximum: 7826),
            SensorInfo(key: "fan.2", label: "Fan 2 speed", kind: .fan, minimum: 2317, maximum: 7826),
            SensorInfo(key: "frequency.cpu.performance", label: "CPU performance cores clock", kind: .frequency,
                       minimum: 1260, maximum: 4512),
            SensorInfo(key: "power.system", label: "Power: whole Mac", kind: .power),
            SensorInfo(key: "gpu.usage", label: "GPU usage", kind: .percent),
        ]
        return s
    }
}

private func sensorSkin(_ t: TestRunner, _ ini: String, _ system: CatalogSystem) throws -> (Skin, FakeHost) {
    try makeSkin(t, "[Rainmeter]\nUpdate=1000\n" + ini, system: system)
}

private func value(_ skin: Skin, _ name: String) -> Double { skin.measure(named: name)?.value ?? -999 }
private func string(_ skin: Skin, _ name: String) -> String { skin.measure(named: name)?.stringValue ?? "<none>" }

/// Spins the main run loop until `condition` holds or `timeout` passes.
@discardableResult
private func spinUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.002))
    }
    return true
}

func runSensorPluginTests(_ t: TestRunner) {
    CorePlugins.register()

    t.suite("Plugin: sensors: catalog keys, kinds and aliases") {
        for entry in SensorKeys.common {
            t.check(SensorKeys.kind(of: entry.key) != nil, "\(entry.key) is a catalog key")
            t.check(!entry.label.isEmpty, "\(entry.key) has a label")
        }
        t.equal(Set(SensorKeys.common.map(\.key)).count, SensorKeys.common.count, "no key twice")
        t.equal(SensorKeys.kind(of: "cpu"), .temperature)
        t.equal(SensorKeys.kind(of: "cpu.core.12"), .temperature)
        t.equal(SensorKeys.kind(of: "cpu.core.0"), nil, "numbered keys count from 1")
        t.equal(SensorKeys.kind(of: "cpu.core.x"), nil)
        t.equal(SensorKeys.kind(of: "fan.2"), .fan)
        t.equal(SensorKeys.kind(of: "fan.2.max"), .fan)
        t.equal(SensorKeys.kind(of: "fan.2.speed"), nil)
        t.equal(SensorKeys.kind(of: "power.system"), .power)
        t.equal(SensorKeys.kind(of: "power.toaster"), nil)
        t.equal(SensorKeys.kind(of: "frequency.cpu.7"), .frequency)
        t.equal(SensorKeys.kind(of: "frequency.gpu.memory"), .frequency)
        t.equal(SensorKeys.kind(of: "voltage.cpu"), .voltage)
        t.equal(SensorKeys.kind(of: "gpu.usage"), .percent)
        t.equal(SensorKeys.kind(of: "gpu.memory"), .bytes)
        t.equal(SensorKeys.kind(of: "battery.health"), .percent)
        t.equal(SensorKeys.kind(of: "battery.cycles"), .count)
        t.equal(SensorKeys.kind(of: "battery.current"), .current)
        t.equal(SensorKeys.kind(of: "Battery.Temperature"), .temperature, "alias, any case")
        t.equal(SensorKeys.kind(of: "bogus"), nil)
        t.equal(SensorKeys.canonical("  CPU.Package "), "cpu")
        t.equal(SensorKeys.canonical("\"Fan\""), "fan.1")
        t.equal(SensorKeys.canonical("GPU.Temperature"), "gpu")
        t.equal(SensorKeys.fan(2, .target), "fan.2.target")
        t.equal(SensorKeys.fan(1), "fan.1")
        // Readings as text.
        t.equal(SensorKeys.text(52.4, kind: .temperature), "52 °C")
        t.equal(SensorKeys.text(52.4, kind: .temperature, scale: .fahrenheit), "126 °F")
        t.equal(SensorKeys.text(0, kind: .temperature, scale: .kelvin), "273 K")
        t.equal(SensorKeys.text(2296.6, kind: .fan), "2297 RPM")
        t.equal(SensorKeys.text(12.44, kind: .power), "12.4 W")
        t.equal(SensorKeys.text(123.4, kind: .power), "123 W")
        t.equal(SensorKeys.text(-0.01, kind: .power), "0.0 W", "no minus zero")
        t.equal(SensorKeys.text(3504, kind: .frequency), "3504 MHz")
        t.equal(SensorKeys.text(24, kind: .percent), "24 %")
        t.equal(SensorKeys.text(223, kind: .count), "223")
        t.equal(SensorKeys.text(11.891, kind: .voltage), "11.89 V")
        t.equal(SensorKeys.text(-1.465, kind: .current), "-1.47 A")
        t.equal(SensorKeys.text(716_996_608, kind: .bytes), "683.8 MB")
        t.equal(SensorKeys.text(512, kind: .bytes), "512 B")
        t.equal(SensorKeys.text(.nan, kind: .power), "")
        t.equal(TemperatureScale(option: "f"), .fahrenheit)
        t.equal(TemperatureScale(option: " K "), .kelvin)
        t.equal(TemperatureScale(option: "x"), .celsius)
        t.close(TemperatureScale.fahrenheit.convert(100), 212)
        t.close(TemperatureScale.kelvin.convert(0), 273.15)
    }

    t.suite("Plugin: sensors: the per-kind requirements default to catalog keys") {
        let s = CatalogSystem.mac()
        t.equal(s.cpuCoreTemperatures() ?? [], [48, 48, 61.5, 61.5], "cpu.core.1… up to the first missing core")
        t.equal(s.cpuPackageTemperature(), 61.5)
        t.equal(s.cpuCoreFrequencies() ?? [], [1968, 1020, 3504, 4512])
        t.equal(s.cpuPower(), 4.5)
        t.equal(s.cpuVoltage(), 0.85)
        t.equal(s.cpuTDP(), nil, "no TDP on a Mac")
        t.equal(s.fanSpeeds(), [2300, 3913])
        t.equal(s.gpuUtilization(), 24)
        // SpeedFan's fixed order: cpu, gpu, soc, battery, ssd, P, E, then the cores; soc is missing here → 0.
        t.equal(s.temperatures(), [61.5, 44, 0, 31, 38, 61.5, 48, 48, 48, 61.5, 61.5])
        t.equal(s.voltages(), [0.85, 11.891])
        // Nothing in the catalog: empty lists, nil values.
        let empty = CatalogSystem()
        t.equal(empty.cpuCoreTemperatures() == nil, true)
        t.equal(empty.cpuPackageTemperature(), nil)
        t.equal(empty.temperatures(), [])
        t.equal(empty.fanSpeeds(), [])
        t.equal(empty.voltages(), [])
        // Fanless: fan.1 missing → no fans.
        s.values["fan.1"] = nil
        t.equal(s.fanSpeeds(), [])
        // A package reading without per-core keys falls back on the cores' maximum only when `cpu` is missing.
        let cores = CatalogSystem()
        cores.values = ["cpu.core.1": 40, "cpu.core.2": 55]
        t.equal(cores.cpuPackageTemperature(), 55)
        t.equal(cores.temperatures(), [40, 55], "without any fixed key: the cores alone")
    }

    t.suite("Plugin: sensors: CoreTemp reads the catalog") {
        let s = CatalogSystem.mac()
        let (skin, host) = try sensorSkin(t, """
        [Max]
        Measure=Plugin
        Plugin=CoreTemp
        [Core2]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Temperature
        CoreTempIndex=2
        [Core9]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Temperature
        CoreTempIndex=9
        [TjMax]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=TjMax
        [Power]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Power
        [Vid]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Vid
        [Tdp]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=Tdp
        [CpuSpeed]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=CpuSpeed
        [CoreSpeed]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=CoreSpeed
        CoreTempIndex=1
        [Bus]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=BusSpeed
        [Multiplier]
        Measure=Plugin
        Plugin=CoreTemp
        CoreTempType=CoreBusMultiplier
        CoreTempIndex=3
        [T]
        Meter=String
        """, s)
        skin.update()
        t.equal(value(skin, "Max"), 61.5, "MaxTemperature = cpu")
        t.equal(value(skin, "Core2"), 61.5, "CoreTempIndex=2 = cpu.core.3")
        t.equal(value(skin, "Core9"), 0, "no tenth core")
        t.equal(value(skin, "TjMax"), 110)
        t.equal(value(skin, "Power"), 4.5)
        t.equal(value(skin, "Vid"), 0.85)
        t.equal(value(skin, "Tdp"), 0)
        t.equal(value(skin, "CpuSpeed"), 3504, "frequency.cpu")
        t.equal(value(skin, "CoreSpeed"), 1020, "frequency.cpu.2")
        t.equal(value(skin, "Bus"), 100)
        t.close(value(skin, "Multiplier"), 45.12)
        t.check(host.logs.contains { $0.contains("[Tdp]: this Mac reports no Tdp") }, "missing values are logged")
        t.check(host.logs.contains { $0.contains("[Core9]: this Mac reports no Temperature") })
        t.check(!host.logs.contains { $0.contains("needs hardware sensors") }, "a source exists")
        t.check(!host.logs.contains { $0.contains("[Max]") }, "values that exist are not logged")

        // While the source has not read a sensor yet, its absence is not logged.
        let fresh = CatalogSystem()
        fresh.pending = ["cpu", "cpu.core.1"]
        let (early, earlyHost) = try sensorSkin(t, "[Max]\nMeasure=Plugin\nPlugin=CoreTemp\n[T]\nMeter=String\n", fresh)
        early.update()
        t.equal(value(early, "Max"), 0)
        t.check(earlyHost.logs.allSatisfy { !$0.contains("reports no") }, "pending: no note")
        fresh.pending = []
        fresh.values["cpu"] = 50
        early.update()
        t.equal(value(early, "Max"), 50, "the reading arrives at a later update")
    }

    t.suite("Plugin: sensors: SpeedFan has a fixed order on every Mac") {
        let s = CatalogSystem.mac()
        let (skin, host) = try sensorSkin(t, """
        [CPU]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        [GPU]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanNumber=1
        [SoC]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanNumber=2
        [BatteryF]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanNumber=3
        SpeedFanScale=F
        [SSDK]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanNumber=4
        SpeedFanScale=K
        [Core1]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanNumber=7
        [Fan2]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanType=Fan
        SpeedFanNumber=1
        [Fan3]
        Measure=Plugin
        Plugin=SpeedFanPlugin
        SpeedFanType=Fan
        SpeedFanNumber=2
        [Volt]
        Measure=Plugin
        Plugin=SpeedFan
        SpeedFanType=Voltage
        SpeedFanNumber=1
        [T]
        Meter=String
        """, s)
        skin.update()
        t.equal(value(skin, "CPU"), 61.5)
        t.equal(value(skin, "GPU"), 44)
        t.equal(value(skin, "SoC"), 0, "this Mac has no soc sensor: 0 in its place")
        t.close(value(skin, "BatteryF"), 31 * 9 / 5 + 32)
        t.close(value(skin, "SSDK"), 38 + 273.15)
        t.equal(value(skin, "Core1"), 48, "the cores follow the seven fixed temperatures")
        t.equal(value(skin, "Fan2"), 3913)
        t.equal(value(skin, "Fan3"), 0)
        t.equal(value(skin, "Volt"), 11.891)
        t.check(host.logs.contains { $0.contains("[Fan3]: this Mac has no fan number 2 (it has 2)") })
    }

    t.suite("Plugin: sensors: UsageMonitor GPU and thermal zone counters") {
        let s = CatalogSystem.mac()
        let (skin, host) = try sensorSkin(t, """
        [GPU]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=GPU
        [GPUName]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=GPU
        Index=1
        [Thermal]
        Measure=Plugin
        Plugin=UsageMonitor
        Category=Thermal Zone Information
        Counter=Temperature
        [Precise]
        Measure=Plugin
        Plugin=PerfMon
        PerfMonObject=Thermal Zone Information
        PerfMonCounter=High Precision Temperature
        PerfMonInstance=\\_TZ.CPU
        PerfMonDifference=0
        [VRAM]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=VRAM
        [T]
        Meter=String
        """, s)
        skin.update()
        t.equal(value(skin, "GPU"), 24, "the whole GPU")
        t.equal(string(skin, "GPUName"), "GPU", "one instance named GPU")
        t.equal(value(skin, "Thermal"), (61.5 + 273.15).rounded(), "kelvin")
        t.equal(value(skin, "Precise"), ((61.5 + 273.15) * 10).rounded(), "tenths of a kelvin")
        t.equal(value(skin, "VRAM"), 0)
        t.check(!host.logs.contains { $0.contains("GPU usage is not available") }, "GPU usage is available")
        t.check(host.logs.contains { $0.contains("GPU memory per process is not available") })
    }

    t.suite("Plugin: sensors: MSIAfterburner data sources") {
        typealias M = MSIAfterburnerMeasure
        t.equal(M.source(for: "GPU temperature"), .sensor("gpu"))
        t.equal(M.source(for: "gpu1 Temperature"), .sensor("gpu"), "GPU1 is the Mac's GPU")
        t.equal(M.source(for: "GPU2 temperature"), .unsupported)
        t.equal(M.source(for: "  Core   clock "), .sensor("frequency.gpu"))
        t.equal(M.source(for: "GPU core clock"), .sensor("frequency.gpu"))
        t.equal(M.source(for: "Memory clock"), .sensor("frequency.gpu.memory"))
        t.equal(M.source(for: "Memory usage"), .megabytes("gpu.memory"))
        t.equal(M.source(for: "GPU1 memory usage"), .megabytes("gpu.memory"))
        t.equal(M.source(for: "Fan speed"), .fanPercent)
        t.equal(M.source(for: "Fan tachometer"), .fanRPM)
        t.equal(M.source(for: "GPU usage"), .sensor("gpu.usage"))
        t.equal(M.source(for: "GPU power"), .sensor("power.gpu"))
        t.equal(M.source(for: "Power"), .unsupported, "a percentage of the card's power limit: no Mac equivalent")
        t.equal(M.source(for: "CPU temperature"), .sensor("cpu"))
        t.equal(M.source(for: "CPU3 temperature"), .sensor("cpu.core.3"))
        t.equal(M.source(for: "CPU2 usage"), .cpuUsage(2))
        t.equal(M.source(for: "CPU usage"), .cpuUsage(0))
        t.equal(M.source(for: "CPU clock"), .sensor("frequency.cpu"))
        t.equal(M.source(for: "CPU4 clock"), .sensor("frequency.cpu.4"))
        t.equal(M.source(for: "CPU power"), .sensor("power.cpu"))
        t.equal(M.source(for: "RAM usage"), .ramUsage)
        t.equal(M.source(for: "Framerate"), .unsupported)
        t.equal(M.source(for: ""), .unsupported)

        let s = CatalogSystem.mac()
        let (skin, host) = try sensorSkin(t, """
        [Temp]
        Measure=Plugin
        Plugin=Plugins\\MSIAfterburner.dll
        DataSource=GPU temperature
        MaxValue=100
        [Fan]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=Fan speed
        [Tach]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=Fan tachometer
        [Clock]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=Core clock
        [VRAMClock]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=Memory clock
        [VRAM]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=Memory usage
        [CPU2]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=CPU2 usage
        [RAM]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=RAM usage
        [FPS]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=Framerate
        [T]
        Meter=String
        """, s)
        skin.update()
        t.equal(value(skin, "Temp"), 44)
        t.close(value(skin, "Fan"), 3913 / 7826 * 100, "the fastest fan, percent of its maximum")
        t.equal(value(skin, "Tach"), 3913)
        t.equal(value(skin, "Clock"), 338)
        t.equal(value(skin, "VRAMClock"), 0, "unified memory: no memory clock")
        t.close(value(skin, "VRAM"), 716_996_608 / 1_048_576, "MB")
        t.equal(value(skin, "CPU2"), 2, "the CPU measure's core 2 (FakeSystem answers the core number)")
        t.equal(value(skin, "RAM"), 8 * 1024, "MB used")
        t.equal(value(skin, "FPS"), 0)
        t.check(host.logs.contains { $0.contains("DataSource=Framerate has no Mac equivalent") })
        t.check(host.logs.contains { $0.contains("[VRAMClock]: this Mac does not report frequency.gpu.memory") })
        // A discrete GPU's own fan wins over the Mac's fans.
        s.values["gpu.fan"] = 35
        skin.update()
        t.equal(value(skin, "Fan"), 35)
    }

    t.suite("Plugin: sensors: MacSensors values, units, ranges and List") {
        let s = CatalogSystem.mac()
        let (skin, host) = try sensorSkin(t, """
        [CPU]
        Measure=Plugin
        Plugin=MacSensors
        [CPUF]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=CPU.Package
        Scale=F
        [Fan]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=fan.2
        [Power]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=power.system
        [Clock]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=frequency.cpu.performance
        [GPU]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=gpu.usage
        [Memory]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=gpu.memory
        [Cycles]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=battery.cycles
        [Current]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=battery.current
        [Fixed]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=cpu
        MinValue=20
        MaxValue=90
        [Missing]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=fan.3
        [Bogus]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=warp.core
        [T]
        Meter=String
        """, s)
        skin.update()
        guard let cpu = skin.measure(named: "CPU"), let cpuF = skin.measure(named: "CPUF"),
              let fan = skin.measure(named: "Fan"), let power = skin.measure(named: "Power"),
              let clock = skin.measure(named: "Clock"), let gpu = skin.measure(named: "GPU"),
              let fixed = skin.measure(named: "Fixed") else { return t.check(false, "measures") }
        t.check(cpu is MacSensorsMeasure, "Plugin=MacSensors is registered")
        t.equal((cpu as? MacSensorsMeasure)?.sensorKey, "cpu", "Sensor=cpu is the default")
        t.equal(cpu.value, 61.5)
        t.equal(cpu.stringValue, "62 °C")
        t.equal([cpu.minValue, cpu.maxValue], [0, 100], "temperatures: 0–100 °C")
        t.close(cpuF.value, 61.5 * 9 / 5 + 32)
        t.equal(cpuF.stringValue, "143 °F")
        t.equal([cpuF.minValue, cpuF.maxValue], [32, 212], "the range in °F")
        t.equal(fan.value, 3913)
        t.equal(fan.stringValue, "3913 RPM")
        t.equal([fan.minValue, fan.maxValue], [2317, 7826], "a fan's own minimum and maximum")
        t.equal(power.stringValue, "18.2 W")
        t.equal(power.maxValue, 18.25, "power follows the values seen")
        t.equal([clock.minValue, clock.maxValue], [1260, 4512], "a cluster's lowest and highest clock")
        t.equal([gpu.minValue, gpu.maxValue], [0, 100])
        t.equal(gpu.stringValue, "24 %")
        t.equal(string(skin, "Memory"), "683.8 MB")
        t.equal(string(skin, "Cycles"), "223")
        t.equal(string(skin, "Current"), "-1.47 A")
        t.equal([fixed.minValue, fixed.maxValue], [20, 90], "MinValue / MaxValue win")
        t.equal(value(skin, "Missing"), 0)
        t.equal(string(skin, "Missing"), "", "no reading: empty text")
        t.check(host.logs.contains { $0.contains("[Missing]: this Mac has no sensor \"fan.3\"") })
        t.equal(value(skin, "Bogus"), 0)
        t.check(host.logs.contains { $0.contains("\"warp.core\" is not a sensor name") })
        t.check(!s.asked.contains("warp.core"), "an unknown name is never asked for")

        // Pending: no note, empty text; then the reading.
        s.values["fan.3"] = nil
        s.pending = ["frequency.gpu.memory"]
        let (late, lateHost) = try sensorSkin(t, "[M]\nMeasure=Plugin\nPlugin=MacSensors\nSensor=frequency.gpu.memory\n"
                                              + "[T]\nMeter=String\n", s)
        late.update()
        t.equal(string(late, "M"), "")
        t.check(!lateHost.logs.contains { $0.contains("has no sensor") }, "pending: no note")
        s.values["frequency.gpu.memory"] = 1500
        s.pending = []
        late.update()
        t.equal(string(late, "M"), "1500 MHz")

        // List: every sensor with its key, label and reading, logged back on the skin's thread.
        skin.measure(named: "CPU")?.execute(command: "List")
        t.check(spinUntil { host.logs.contains { $0.contains("sensors:") } }, "the list is logged")
        t.check(host.logs.contains { $0.contains("[CPU]: cpu — CPU temperature (hottest sensor): 62 °C") })
        t.check(host.logs.contains { $0.contains("fan.1 — Fan 1 speed: 2300 RPM") })
        skin.measure(named: "CPU")?.execute(command: "Explode")
        t.check(host.logs.contains { $0.contains("unknown command \"Explode\"") })
        t.equal(MacSensorsMeasure.listLines([], values: { _ in nil }, scale: .celsius),
                ["this Mac reports no hardware sensors"])
        t.equal(MacSensorsMeasure.listLines([SensorInfo(key: "gpu", label: "GPU temperature", kind: .temperature)],
                                            values: { _ in nil }, scale: .celsius),
                ["1 sensors:", "gpu — GPU temperature: no reading yet"])
    }

    t.suite("Plugin: sensors: without a sensor source everything is 0, noted once") {
        let (skin, host) = try makeSkin(t, """
        [M]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=gpu
        [A]
        Measure=Plugin
        Plugin=MSIAfterburner
        DataSource=GPU temperature
        [T]
        Meter=String
        """)
        skin.update()
        skin.update()
        t.equal(value(skin, "M"), 0)
        t.equal(value(skin, "A"), 0)
        t.equal(host.logs.filter { $0.contains("hardware sensors are not available here") }.count, 2, "once each")
    }
}
