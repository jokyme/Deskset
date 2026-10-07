import Foundation
@testable import DesksetCore

// What a skin reads about the Mac, given as data (the runtime design, "same inputs on both sides"): JSON values, and
// the `--render --data` fixtures that stand in for the system readings, the battery and the sensors.

func runInputDataTests(_ t: TestRunner) {
    t.suite("Seams: JSON values") {
        let v = try JSONValue.parse(#"{"a": 1, "b": [true, false, null, "x", 2.5], "c": {"d": "e"}, "f": 0}"#)
        t.equal(v["a"], .number(1))
        t.equal(v["b"], .array([.bool(true), .bool(false), .null, .string("x"), .number(2.5)]))
        t.equal(v["c"]?["d"]?.string, "e")
        t.equal(v["f"], .number(0), "0 and 1 stay numbers")
        t.equal(v["missing"], nil)
        t.equal(JSONValue.string("4.5").number, 4.5)
        t.equal(JSONValue.number(4.5)["a"], nil)
        t.equal(try JSONValue.parse("7"), .number(7), "any value at the top")
        t.equal(try JSONValue.parse("null"), .null)
        t.check((try? JSONValue.parse("{nope")) == nil, "bad JSON is an error")
        // Round trip: what is read is written back the same.
        let data = try JSONEncoder().encode(v)
        t.equal(try JSONValue.parse(data), v)
        t.equal(JSONValue.object(["b": .number(1), "a": .string("x/y")]).description, #"{"a":"x/y","b":1}"#)

        // Unknown keys of a type that knows only some.
        struct Known: Codable, Equatable {
            var name = ""
            var unknown: [String: JSONValue] = [:]
            enum CodingKeys: String, CodingKey { case name }
            init(name: String) { self.name = name }
            init(from decoder: Decoder) throws {
                unknown = try decoder.container(keyedBy: AnyCodingKey.self).unknownValues(besides: ["name"])
                name = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .name)
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(name, forKey: .name)
                var other = encoder.container(keyedBy: AnyCodingKey.self)
                try other.encodeUnknown(unknown, besides: ["name"])
            }
        }
        let known = try JSONDecoder().decode(Known.self, from: Data(#"{"name": "n", "later": {"x": [1]}}"#.utf8))
        t.equal(known.name, "n")
        t.equal(known.unknown, ["later": .object(["x": .array([.number(1)])])])
        let written = try JSONValue.parse(try JSONEncoder().encode(known))
        t.equal(written, .object(["name": .string("n"), "later": .object(["x": .array([.number(1)])])]))
        var clash = Known(name: "mine")
        clash.unknown = ["name": .string("theirs")]
        t.equal(try JSONValue.parse(try JSONEncoder().encode(clash))["name"], .string("mine"),
                "a kept key never overrides one the type writes")
    }

    t.suite("Seams: --data: reading the data object") {
        let dir = t.temporaryDirectory("input-data")
        try Data([0x89, 0x50]).write(to: dir.appendingPathComponent("cover.png"))
        try #"{"type":"Feature","geometry":{"type":"Point","coordinates":[10.75,59.91,3]},"properties":{}}"#
            .write(to: dir.appendingPathComponent("oslo.json"), atomically: true, encoding: .utf8)
        try #"{"frames": [{"cpu": [20, 10, 30], "uptime": 100}, {"cpu": 50}]}"#
            .write(to: dir.appendingPathComponent("system.json"), atomically: true, encoding: .utf8)
        let text = #"""
        {"system": "system.json",
         "battery": {"level": 42, "charging": false, "timeRemaining": 180},
         "sensors": {"CPU": 51.5, "fan.1": {"value": 2300, "min": 1200, "max": 6000}, "thermal": 1, "gpu": null},
         "nowPlaying": {"player": "spotify", "state": "paused", "artist": "A", "title": "T", "album": "B",
                        "position": 83, "duration": 245, "cover": "cover.png", "repeat": "all"},
         "audio": {"frames": [{"rms": [0.5, 0.25], "peak": 0.8, "bands": [0.1, 0.2, 0.3]}]},
         "weather": "oslo.json",
         "wifi": {"ssid": "Home", "rssi": -55, "transmitRate": 866, "networks": [{"ssid": "Cafe", "rssi": -70}]},
         "desktopImage": "cover.png",
         "trash": {"count": 3, "size": 2048},
         "later": 1}
        """#
        try text.write(to: dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8)
        let d = try SkinInputData.load("data.json", directory: dir)
        t.equal(d.givenKeys, SkinInputData.keys.filter { $0 != "programs" })
        t.equal(d.unknownKeys, ["later"], "a key of a newer format is reported, not an error")
        t.equal(d.system?.count, 2)
        t.equal(d.system?[0].cpu, [20, 10, 30])
        t.equal(d.system?[1].cpu, [50])
        t.equal(d.system?[1].uptime, 100, "a frame keeps what it leaves out from the one before")
        t.equal(d.battery, .value(BatteryStatus(percent: 42, isCharging: false, isPluggedIn: false, minutesRemaining: 180)))
        t.equal(d.sensors?["cpu"]?.value, 51.5, "sensor keys are canonical")
        t.equal(d.sensors?["fan.1"]?.maximum, 6000)
        t.equal(d.sensors?["gpu"], nil, "null: the Mac has no such sensor")
        t.equal(d.thermalState, 1)
        let np = d.nowPlaying?.value
        t.equal(np?.player, "spotify")
        t.equal(np?.state, 2)
        t.equal(np?.repeatMode, 2)
        t.equal(np?.cover, dir.appendingPathComponent("cover.png").standardizedFileURL.path, "paths are the file's")
        let audio = d.audio?.value
        t.equal(audio?.frames.first?.rms, [0.5, 0.25])
        t.equal(audio?.frames.first?.peak, [0.8, 0.8], "one value is every channel's")
        t.equal(audio?.frames.first?.bands, [[0.1, 0.2, 0.3]])
        let weather = d.weather?.value
        t.equal(weather?.status, 200)
        t.equal(weather?.location, .forecast)
        t.equal(weather?.forecastPoint?.latitude, 59.91)
        t.equal(d.wifi?.value?.current.ssid, "Home")
        t.equal(d.wifi?.value?.networks.map(\.rssi), [-70])
        t.equal(d.desktopImage?.value, np?.cover)
        t.equal(d.trash?.value, SkinInputData.Trash(count: 3, size: 2048))

        // null: there is none. A key left out: the service stays live.
        let none = try SkinInputData.load(#"{"battery": null, "nowPlaying": null, "weather": null, "wifi": null, "desktopImage": null, "trash": null}"#,
                                          directory: dir)
        t.equal(none.trash, SkinInputData.Given<SkinInputData.Trash>.none, "null: an empty Trash")
        t.equal(try SkinInputData.load(#"{"trash": 5}"#, directory: dir).trash?.value,
                SkinInputData.Trash(count: 5), "a number: the count")
        t.equal(try SkinInputData.load(#"{"trash": {"count": 2, "size": null}}"#, directory: dir).trash?.value,
                SkinInputData.Trash(count: 2, size: nil), "size null: it cannot be read")
        t.equal(none.battery, SkinInputData.Given<BatteryStatus>.none)
        t.equal(none.nowPlaying, SkinInputData.Given<SkinInputData.NowPlaying>.none)
        t.equal(none.weather, SkinInputData.Given<SkinInputData.Weather>.none)
        t.equal(none.system, nil)
        t.check(SkinInputData().isEmpty)
        let noLocation = try SkinInputData.load(#"{"weather": {"forecast": "oslo.json", "location": null}}"#, directory: dir)
        t.equal(noLocation.weather?.value?.location, SkinInputData.Weather.Location.none)
        let offline = try SkinInputData.load(#"{"weather": {"location": [59.9, 10.7]}}"#, directory: dir)
        t.equal(offline.weather?.value?.forecast, nil)
        t.equal(offline.weather?.value?.location, .coordinate(latitude: 59.9, longitude: 10.7))

        // An event script: its data object.
        let script = try SkinInputData.load(#"{"update": 1000, "seed": 7, "data": {"battery": {"level": 5}}, "steps": []}"#,
                                            directory: dir)
        t.equal(script.battery?.value?.percent, 5)

        // Mistakes name the key.
        func failure(_ json: String) -> String {
            switch Result(catching: { try SkinInputData.load(json, directory: dir) }) {
            case .success: return "no error"
            case .failure(let e): return "\(e)"
            }
        }
        t.equal(failure(#"{"system": {"cpu": "high"}}"#), "system.cpu: is not a number or a list of numbers")
        t.equal(failure(#"{"system": {"frames": [{"cpu": 1}, {"gpu": 2}]}}"#).hasPrefix("system.frames[1].gpu: is not a system reading"), true)
        t.equal(failure(#"{"sensors": {"cpu.teapot": 3}}"#), "sensors.cpu.teapot: is not a sensor key")
        t.equal(failure(#"{"nowPlaying": {"state": "dancing"}}"#), "nowPlaying.state: is not playing, paused or stopped")
        t.equal(failure(#"{"weather": "missing.json"}"#).hasPrefix("weather: cannot read"), true)
        t.equal(failure(#"{"system": "missing.json"}"#).hasPrefix("system: cannot read"), true)
        t.equal(failure(#"{"trash": {"count": "many"}}"#), "trash.count: is not a number")
        try "[1]".write(to: dir.appendingPathComponent("list.json"), atomically: true, encoding: .utf8)
        t.equal(failure("list.json"), "the data is not a JSON object")
        t.check(failure("{nope").hasPrefix("not JSON"), failure("{nope"))
        t.check(failure("nothing-here.json").hasPrefix("cannot read"), "a path that does not exist")
    }

    t.suite("Seams: --data: battery charge estimates preserve replay units and old discharge values") {
        let dir = t.temporaryDirectory("battery-estimates")
        func read(_ source: String) throws -> SkinInputData { try SkinInputData.load(source, directory: dir) }
        let charge = try read(#"{"battery":{"level":50,"charging":true,"timeRemaining":125,"timeUntilFull":45}}"#)
        t.equal(charge.battery, .value(BatteryStatus(percent: 50, isCharging: true, isPluggedIn: true,
                                                    minutesRemaining: 125, minutesUntilFull: 45)))
        let replay = ScriptedSystemData(base: FakeSystem(), data: charge)
        let input = ProgramSystemInput.sample(from: replay, for: [.batteryPresent, .batteryTimeRemaining])
        t.equal(input.batteryPresent, true)
        t.equal(input.batteryTimeRemaining, 2700, "the program converts charge minutes to seconds exactly once")
        let drain = try read(#"{"battery":{"charging":false,"timeRemaining":125,"timeUntilFull":45}}"#)
        t.equal(ProgramSystemInput.sample(from: ScriptedSystemData(base: FakeSystem(), data: drain),
                                         for: [.batteryTimeRemaining]).batteryTimeRemaining, 7500,
                "the discharge path keeps its existing field")
        for field in ["", ",\"timeUntilFull\":null"] {
            let unknown = try read("{\"battery\":{\"charging\":true\(field)}}")
            t.equal(unknown.battery?.value?.minutesUntilFull, nil)
            t.equal(ProgramSystemInput.sample(from: ScriptedSystemData(base: FakeSystem(), data: unknown),
                                             for: [.batteryTimeRemaining]).batteryTimeRemaining, nil)
        }
        for (estimate, expected) in [(0, Optional(0.0)), (-1, nil)] {
            let data = try read("{\"battery\":{\"charging\":true,\"timeUntilFull\":\(estimate)}}")
            t.equal(ProgramSystemInput.sample(from: ScriptedSystemData(base: FakeSystem(), data: data),
                                             for: [.batteryTimeRemaining]).batteryTimeRemaining, expected)
        }
        let absent = try read(#"{"battery":null}"#)
        let none = ProgramSystemInput.sample(from: ScriptedSystemData(base: FakeSystem(), data: absent),
                                            for: [.batteryPresent, .batteryTimeRemaining])
        t.equal(none.batteryPresent, false); t.equal(none.batteryTimeRemaining, nil)
        for invalid in ["true", "\"45\"", "[]", "{}"] {
            do {
                _ = try read("{\"battery\":{\"timeUntilFull\":\(invalid)}}")
                t.check(false, "charge estimates require a numeric replay value")
            } catch {
                t.equal(String(describing: error), "battery.timeUntilFull: is not a number")
            }
        }
    }

    t.suite("Seams: --data: programs, the weather transport and the device location") {
        let dir = t.temporaryDirectory("programs")
        let d = try SkinInputData.load(#"""
        {"programs": {"sysctl": "1\n", "sysctl -n hw.ncpu": "8\n", "profiler": ["a=1", "b=2"]}}
        """#, directory: dir)
        t.equal(d.programOutput(for: "/usr/sbin/sysctl -n hw.ncpu"), "8\n", "the longest match wins")
        t.equal(d.programOutput(for: "/usr/sbin/sysctl -n hw.memsize"), "1\n")
        t.equal(d.programOutput(for: "system_profiler SPPowerDataType"), "a=1\nb=2\n", "a list of lines")
        t.equal(d.programOutput(for: "echo hi"), "", "a program the data does not give writes nothing")
        t.equal(d.givenKeys, ["programs"])
        t.check((try? SkinInputData.load(#"{"programs": {"x": 1}}"#, directory: dir)) == nil, "output must be text")

        let request = METNorway.request(endpoint: METNorway.endpoint,
                                        for: RoundedCoordinate(latitude: 59.91, longitude: 10.75),
                                        userAgent: "test", lastModified: nil)
        let transport = FixtureWeatherTransport(body: Data("{}".utf8), status: 203)
        var answer: Result<WeatherHTTPResponse, WeatherTransportError>?
        transport.get(request) { answer = $0 }
        t.equal(try answer?.get().status, 203, "answered before get returns")
        t.equal(transport.requests, 1)
        let offline = FixtureWeatherTransport(body: nil)
        offline.get(request) { answer = $0 }
        if case .failure(.network)? = answer {} else { t.check(false, "no body: offline") }

        let here = FixedDeviceLocation(RoundedCoordinate(latitude: 59.91, longitude: 10.75))
        t.equal(here.authorization, .authorized)
        var fix: Result<RoundedCoordinate, DeviceLocationError>?
        here.requestFix { fix = $0 }
        t.equal(try fix?.get().latitude, 59.91)
        let nowhere = FixedDeviceLocation(nil)
        t.equal(nowhere.authorization, .denied)
        nowhere.requestFix { fix = $0 }
        t.equal(fix.map { if case .failure(.denied) = $0 { return true } else { return false } }, true)
        t.equal(nowhere.cachedFix(maxAge: 1e9), nil)
    }

    t.suite("Seams: --data: the scripted system readings") {
        let live = FakeSystem()
        let frames = try SkinInputData.load(#"""
        {"system": {"frames": [
            {"cpu": [25, 10, 40], "memory": {"physicalTotal": 1000, "physicalUsed": 400},
             "network": {"en0": {"received": 100, "sent": 10}, "en1": {"received": 5, "sent": 1}},
             "disks": {"/": {"total": 500, "free": 100, "label": "Macintosh HD"},
                       "/Volumes/Backup": {"total": 50, "free": 40, "available": 45, "kind": "removable"}},
             "uptime": 3600, "sysInfo": {"COMPUTER_NAME": "Studio", "IP_ADDRESS:1": "10.0.0.2"},
             "processes": [{"name": "Safari", "pid": 10, "cpu": 20, "memory": 900}]},
            {"cpu": [75, 70, 80], "uptime": 3601}]}}
        """#, directory: t.temporaryDirectory("frames"))
        let s = ScriptedSystemData(base: live, data: frames)
        t.equal(s.processorCount, 2)
        t.equal(s.cpuUsage(processor: 0), 25)
        t.equal(s.cpuUsage(processor: 2), 40)
        t.equal(s.cpuUsage(processor: 5), 0)
        t.equal(s.memoryStatus().physicalUsed, 400)
        t.equal(s.networkInterfaces(), ["en0", "en1"])
        t.equal(s.networkCounters(interface: nil), NetworkCounters(received: 105, sent: 11))
        t.equal(s.networkCounters(interface: "en1").received, 5)
        t.equal(s.bestNetworkInterface(), "en0")
        t.equal(s.diskSpace(path: "/Users/me")?.free, 100)
        t.equal(s.diskSpace(path: "/Volumes/Backup/Photos")?.total, 50, "the longest mount point holding the path")
        t.equal(s.availableDiskSpace(path: "/Volumes/Backup"), 45)
        t.equal(s.availableDiskSpace(path: "/"), 100, "available defaults to free")
        t.equal(s.volumeInfo(path: "/Volumes/Backup")?.kind, .removable)
        t.equal(s.uptime(), 3600)
        t.equal(s.sysInfo(type: "computer_name", data: "")?.string, "Studio")
        t.equal(s.sysInfo(type: "IP_ADDRESS", data: "1")?.string, "10.0.0.2")
        t.check(s.sysInfo(type: "USER_NAME", data: "") == nil, "with system given, nothing comes from the Mac")
        t.check(s.isProcessRunning("safari"))
        t.check(!s.isProcessRunning("Finder"))
        t.equal(s.battery()?.percent, 80, "battery not given: the live one")
        t.equal(s.frameIndex, 0)
        s.advance()
        t.equal(s.cpuUsage(processor: 0), 75)
        t.equal(s.memoryStatus().physicalUsed, 400, "the second frame keeps the first one's memory")
        t.equal(s.uptime(), 3601)
        s.advance()
        t.equal(s.frameIndex, 1, "the last frame stays")

        // Nothing given: the live source answers everything.
        let passthrough = ScriptedSystemData(base: live, data: SkinInputData())
        t.equal(passthrough.cpuUsage(processor: 0), 42)
        t.equal(passthrough.uptime(), 90061)
        t.equal(passthrough.processorCount, 8)
        t.equal(passthrough.sysInfo(type: "USER_NAME", data: "")?.string, "tester")
        t.check(passthrough.processSamples() == nil)

        // Battery, sensors, the desktop picture.
        let other = try SkinInputData.load(#"""
        {"battery": null, "sensors": {"cpu": 60, "fan.1": {"value": 2000, "min": 1000, "max": 5000}, "thermal": 2},
         "desktopImage": null}
        """#, directory: t.temporaryDirectory("frames"))
        let o = ScriptedSystemData(base: live, data: other)
        t.check(o.battery() == nil, "null: a Mac without a battery")
        t.equal(o.sensorValue("CPU"), 60)
        t.equal(o.sensorValue("fan.1.max"), 5000)
        t.equal(o.sensorInfo("fan.1")?.minimum, 1000)
        t.equal(o.sensorValue("gpu"), nil)
        t.check(!o.sensorPending("gpu"), "a sensor left out is missing, not pending")
        t.equal(o.cpuPackageTemperature(), 60)
        t.equal(o.fanSpeeds(), [2000])
        t.equal(o.thermalState(), 2)
        t.equal(o.desktopPicturePath(), "")
        t.equal(o.cpuUsage(processor: 0), 42, "system not given: live")
        var listed: [SensorInfo] = []
        o.discoverSensors { listed = $0 }
        t.equal(listed.map(\.key), ["cpu", "fan.1"])
        o.apply(try SkinInputData.load(#"{"battery": {"level": 9, "charging": true}}"#, directory: t.temporaryDirectory("frames")))
        t.equal(o.battery()?.isPluggedIn, true, "charging means on AC unless it says otherwise")
        t.equal(o.sensorValue("cpu"), 60, "applying data changes only what it gives")
    }

    t.suite("Seams: --data: a skin reads the scripted Mac") {
        let dir = t.temporaryDirectory("data-skin").appendingPathComponent("Skins/Root/Sub")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
        [Rainmeter]
        Update=1000
        [CPU]
        Measure=CPU
        [Core2]
        Measure=CPU
        Processor=2
        [Mem]
        Measure=PhysicalMemory
        [Disk]
        Measure=FreeDiskSpace
        Drive=/
        [Up]
        Measure=Uptime
        [Top]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=CPU
        Index=1
        [TopRAM]
        Measure=Plugin
        Plugin=UsageMonitor
        Alias=RAM
        Index=1
        [Temp]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=cpu
        [Thermal]
        Measure=Plugin
        Plugin=MacSensors
        Sensor=thermal
        [Power]
        Measure=Plugin
        Plugin=PowerPlugin
        PowerState=Percent
        [Name]
        Measure=SysInfo
        SysInfoType=COMPUTER_NAME
        [Meter]
        Meter=String
        MeasureName=Top
        """.write(to: dir.appendingPathComponent("Skin.ini"), atomically: true, encoding: .utf8)
        let data = try SkinInputData.load(#"""
        {"system": {"frames": [
            {"cpu": [30, 20, 40], "memory": {"physicalTotal": 1000, "physicalUsed": 250},
             "disks": {"/": {"total": 500, "free": 125}}, "uptime": 7200, "sysInfo": {"COMPUTER_NAME": "Test Mac"},
             "processes": [{"name": "Music", "pid": 20, "cpu": 12, "memory": 300},
                           {"name": "Safari", "pid": 10, "cpu": 8, "memory": 900}]},
            {"cpu": [60, 50, 70],
             "processes": [{"name": "Music", "pid": 20, "cpu": 4, "memory": 300},
                           {"name": "Safari", "pid": 10, "cpu": 40, "memory": 900}]}]},
         "battery": {"level": 64}, "sensors": {"cpu": 48.5, "thermal": 1}}
        """#, directory: dir)
        let system = ScriptedSystemData(base: FakeSystem(), data: data)
        let host = FakeHost()
        let skin = Skin(config: "Root\\Sub", fileURL: dir.appendingPathComponent("Skin.ini"),
                        skinsDirectory: dir.deletingLastPathComponent().deletingLastPathComponent(), system: system,
                        host: host)
        try skin.load()
        skin.update()
        func v(_ m: String) -> Double { skin.measure(named: m)?.value ?? .nan }
        func s(_ m: String) -> String { skin.measure(named: m)?.stringValue ?? "<none>" }
        t.equal(v("CPU"), 30)
        t.equal(v("Core2"), 40)
        t.equal(v("Mem"), 250)
        t.equal(v("Disk"), 125)
        t.equal(v("Up"), 7200)
        t.equal(s("Top"), "Music", "the busiest process of the frame")
        t.close(v("Top"), 12, accuracy: 1e-6)
        t.equal(s("TopRAM"), "Safari")
        t.equal(v("TopRAM"), 900)
        t.equal(v("Temp"), 48.5)
        t.equal(v("Thermal"), 1)
        t.equal(s("Thermal"), "Fair")
        t.equal(v("Power"), 64)
        t.equal(s("Name"), "Test Mac")
        system.advance()
        skin.update()
        t.equal(v("CPU"), 60)
        t.equal(s("Top"), "Safari", "the next frame's processes")
        t.close(v("Top"), 40, accuracy: 1e-6)
        t.equal(v("Up"), 7200, "kept from the frame before")
        _ = host
    }
}
