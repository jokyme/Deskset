import Foundation

// What a skin reads about the Mac, given as data (the runtime design, "same inputs on both sides": the `data` object
// of an event script, and `Deskset --render --data`). Each key stands in for one service behind the protocol the
// engine already reads it through:
//
//   system        SystemDataSource: a sequence of frames (CPU, memory, network, disks, uptime, processes, SysInfo…)
//   battery       SystemDataSource.battery()
//   sensors       HardwareSensorSource (MacSensors, CoreTemp, SpeedFan, UsageMonitor's sensor counters…)
//   nowPlaying    the app's NowPlaying backend
//   audio         the app's AudioLevel analysis: a sequence of levels and bands
//   weather       the weather service's transport: MET Norway's raw JSON
//   wifi          the app's Wi-Fi reader
//   desktopImage  the desktop picture (Chameleon, the Registry's Wallpaper)
//
// A key that is not given leaves that service live. `null` means "there is none": no battery, no player, no network
// for the weather, no Wi-Fi interface, no desktop picture. The format: docs/COMPATIBILITY.md, "--render --data".

/// The `data` object, read and checked. Paths in it are absolute (made so relative to the data file's folder).
public struct SkinInputData: Equatable, Sendable {
    /// A value that may be given as `null`: `.none` is "there is none", as opposed to the key not being given (the
    /// property is nil then, and the service stays live).
    public enum Given<T: Equatable & Sendable>: Equatable, Sendable {
        case none
        case value(T)

        public var value: T? {
            if case .value(let v) = self { return v }
            return nil
        }
    }

    // MARK: Values

    /// One frame of system readings: what the Mac reports during one update. A key a frame leaves out keeps the
    /// previous frame's value.
    public struct SystemFrame: Equatable, Sendable {
        /// CPU use 0–100: the whole CPU first, then each core (`Processor=0`, `1`, `2`…).
        public var cpu: [Double]?
        public var memory: MemoryStatus?
        /// Cumulative bytes by interface (`en0`…).
        public var network: [String: NetworkCounters]?
        /// `Interface=Best`; default: the first interface by name.
        public var bestInterface: String?
        /// Volumes by mount point (`/`, `/Volumes/Backup`).
        public var disks: [String: Disk]?
        /// Seconds since the Mac started.
        public var uptime: Double?
        public var processes: [Process]?
        /// SysInfo answers by `SysInfoType` (upper case), or `TYPE:data` for one `SysInfoData`.
        public var sysInfo: [String: SysInfoAnswer]?
        /// Hz.
        public var cpuFrequency: Double?
        public var graphicsAdapter: String?

        public init() {}

        /// This frame with the keys it leaves out taken from `previous`.
        func over(_ previous: SystemFrame) -> SystemFrame {
            var f = self
            f.cpu = cpu ?? previous.cpu
            f.memory = memory ?? previous.memory
            f.network = network ?? previous.network
            f.bestInterface = bestInterface ?? previous.bestInterface
            f.disks = disks ?? previous.disks
            f.uptime = uptime ?? previous.uptime
            f.processes = processes ?? previous.processes
            f.sysInfo = sysInfo ?? previous.sysInfo
            f.cpuFrequency = cpuFrequency ?? previous.cpuFrequency
            f.graphicsAdapter = graphicsAdapter ?? previous.graphicsAdapter
            return f
        }
    }

    public struct Disk: Equatable, Sendable {
        /// Bytes.
        public var total: Double
        public var free: Double
        /// Finder's available space (free plus purgeable); default: `free`.
        public var available: Double?
        public var label: String
        public var kind: VolumeInfo.Kind

        public init(total: Double, free: Double, available: Double? = nil, label: String = "", kind: VolumeInfo.Kind = .fixed) {
            self.total = total
            self.free = free
            self.available = available
            self.label = label
            self.kind = kind
        }
    }

    public struct Process: Equatable, Sendable {
        public var name: String
        public var pid: Int32
        /// Share of the whole Mac's CPU during the frame, 0–100.
        public var cpu: Double
        /// Bytes of memory.
        public var memory: Double

        public init(name: String, pid: Int32, cpu: Double, memory: Double = 0) {
            self.name = name
            self.pid = pid
            self.cpu = cpu
            self.memory = memory
        }
    }

    public struct SysInfoAnswer: Equatable, Sendable {
        public var number: Double
        public var string: String?

        public init(number: Double, string: String? = nil) {
            self.number = number
            self.string = string
        }
    }

    public struct Sensor: Equatable, Sendable {
        /// nil: the Mac has the sensor, without a reading yet.
        public var value: Double?
        /// The lowest and highest value the hardware reports (a fan's speeds).
        public var minimum: Double?
        public var maximum: Double?
        public var label: String?

        public init(value: Double?, minimum: Double? = nil, maximum: Double? = nil, label: String? = nil) {
            self.value = value
            self.minimum = minimum
            self.maximum = maximum
            self.label = label
        }
    }

    public struct NowPlaying: Equatable, Sendable {
        /// `music` (Apple Music) or `spotify`.
        public var player: String
        /// 0 stopped, 1 playing, 2 paused.
        public var state: Int
        public var artist: String
        public var title: String
        public var album: String
        /// Seconds.
        public var position: Double
        public var duration: Double
        /// An image file (absolute), or nil for no artwork.
        public var cover: String?
        /// 0–100.
        public var volume: Double
        public var shuffle: Bool
        /// 0 off, 1 one track, 2 all.
        public var repeatMode: Int
        /// 0–100.
        public var rating: Double

        public init(player: String = "music", state: Int = 1, artist: String = "", title: String = "", album: String = "", position: Double = 0, duration: Double = 0, cover: String? = nil, volume: Double = 70, shuffle: Bool = false, repeatMode: Int = 0, rating: Double = 0) {
            self.player = player
            self.state = state
            self.artist = artist
            self.title = title
            self.album = album
            self.position = position
            self.duration = duration
            self.cover = cover
            self.volume = volume
            self.shuffle = shuffle
            self.repeatMode = repeatMode
            self.rating = rating
        }
    }

    /// One frame of audio analysis: the levels a parent AudioLevel measure reports, 0–1, per channel (left, right…;
    /// the Sum is their mean), before its RMSGain / PeakGain.
    public struct AudioFrame: Equatable, Sendable {
        public var rms: [Double]
        public var peak: [Double]
        /// Per channel, `Bands` values each (a single list is used for every channel).
        public var bands: [[Double]]
        /// Per channel, `FFTSize / 2 + 1` values each (a single list is used for every channel).
        public var fft: [[Double]]

        public init(rms: [Double], peak: [Double], bands: [[Double]] = [], fft: [[Double]] = []) {
            self.rms = rms
            self.peak = peak
            self.bands = bands
            self.fft = fft
        }
    }

    public struct Audio: Equatable, Sendable {
        public var frames: [AudioFrame]
        /// The source's name, format and channel count.
        public var deviceName: String
        public var sampleRate: Double
        public var channels: Int

        public init(frames: [AudioFrame], deviceName: String = "Deskset Test Signal", sampleRate: Double = 48000, channels: Int = 2) {
            self.frames = frames
            self.deviceName = deviceName
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }

    public struct Weather: Equatable, Sendable {
        public enum Location: Equatable, Sendable {
            /// This Mac's location (`Location=auto`) is the forecast's own point.
            case forecast
            case coordinate(latitude: Double, longitude: Double)
            /// Location Services give no location.
            case none
        }

        /// A MET Norway locationforecast 2.0 response (the file's bytes); nil: no network.
        public var forecast: Data?
        /// Where the file came from (reports).
        public var forecastPath: String?
        /// The HTTP status of the answer (200).
        public var status: Int
        public var location: Location

        public init(forecast: Data?, forecastPath: String? = nil, status: Int = 200, location: Location = .forecast) {
            self.forecast = forecast
            self.forecastPath = forecastPath
            self.status = status
            self.location = location
        }

        /// The forecast's own point (from its `geometry`), when it has one.
        public var forecastPoint: (latitude: Double, longitude: Double)? {
            guard let forecast, let json = try? JSONValue.parse(forecast),
                  let c = json["geometry"]?["coordinates"]?.array, c.count >= 2,
                  let lon = c[0].number, let lat = c[1].number else { return nil }
            return (lat, lon)
        }
    }

    public struct WiFiNetwork: Equatable, Sendable {
        public var ssid: String
        /// dBm (0 = unknown).
        public var rssi: Int
        /// Mbps.
        public var transmitRate: Double
        public var encryption: String
        public var auth: String
        public var phy: String

        public init(ssid: String, rssi: Int = 0, transmitRate: Double = 0, encryption: String = "AES", auth: String = "WPA2-Personal", phy: String = "802.11ax") {
            self.ssid = ssid
            self.rssi = rssi
            self.transmitRate = transmitRate
            self.encryption = encryption
            self.auth = auth
            self.phy = phy
        }
    }

    public struct WiFi: Equatable, Sendable {
        public var current: WiFiNetwork
        /// Visible networks (`WiFiInfoType=LIST`).
        public var networks: [WiFiNetwork]

        public init(current: WiFiNetwork, networks: [WiFiNetwork] = []) {
            self.current = current
            self.networks = networks
        }
    }

    // MARK: Keys

    public var system: [SystemFrame]?
    public var battery: Given<BatteryStatus>?
    /// Canonical sensor keys (`SensorKeys.canonical`); a key left out is a sensor this Mac does not have.
    public var sensors: [String: Sensor]?
    /// macOS's thermal state 0–3 (`sensors.thermal`).
    public var thermalState: Int?
    public var nowPlaying: Given<NowPlaying>?
    public var audio: Given<Audio>?
    public var weather: Given<Weather>?
    public var wifi: Given<WiFi>?
    public var desktopImage: Given<String>?
    /// Keys the reader did not know (a newer format): reported, not an error.
    public var unknownKeys: [String] = []

    public init() {}

    /// True when no key is given.
    public var isEmpty: Bool {
        system == nil && battery == nil && sensors == nil && thermalState == nil && nowPlaying == nil && audio == nil
            && weather == nil && wifi == nil && desktopImage == nil
    }

    /// The keys given, in the order of the format.
    public var givenKeys: [String] {
        var keys: [String] = []
        if system != nil { keys.append("system") }
        if battery != nil { keys.append("battery") }
        if sensors != nil || thermalState != nil { keys.append("sensors") }
        if nowPlaying != nil { keys.append("nowPlaying") }
        if audio != nil { keys.append("audio") }
        if weather != nil { keys.append("weather") }
        if wifi != nil { keys.append("wifi") }
        if desktopImage != nil { keys.append("desktopImage") }
        return keys
    }
}

// MARK: - Reading

/// Why the data cannot be used: the key (`system.frames[2].cpu`) and what is wrong with it.
public struct SkinInputDataError: Error, Equatable, CustomStringConvertible {
    public var key: String
    public var message: String

    public init(_ key: String, _ message: String) {
        self.key = key
        self.message = message
    }

    public var description: String { key.isEmpty ? message : "\(key): \(message)" }
}

extension SkinInputData {
    /// The keys the format knows.
    public static let keys = ["system", "battery", "sensors", "nowPlaying", "audio", "weather", "wifi", "desktopImage"]

    /// Reads `--data`: JSON text (starting with `{`) or the path of a JSON file. Relative paths inside are relative
    /// to the file's folder (to `directory` for text). A whole event script (with `data`, `steps`…) is read for its
    /// `data` object.
    public static func load(_ argument: String, directory: URL) throws -> SkinInputData {
        let text = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            return try parse(Data(text.utf8), directory: directory)
        }
        let url = URL(fileURLWithPath: text, relativeTo: directory).standardizedFileURL
        guard let data = try? Data(contentsOf: url) else {
            throw SkinInputDataError("", "cannot read \(url.path)")
        }
        return try parse(data, directory: url.deletingLastPathComponent())
    }

    public static func parse(_ data: Data, directory: URL) throws -> SkinInputData {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch {
            throw SkinInputDataError("", "not JSON (\(error.localizedDescription))")
        }
        return try SkinInputDataReader(directory: directory).read(json)
    }
}

/// Reads the JSON of the format into `SkinInputData`, checking every value.
struct SkinInputDataReader {
    let directory: URL

    func read(_ json: JSONValue) throws -> SkinInputData {
        guard var top = json.object else { throw SkinInputDataError("", "the data is not a JSON object") }
        // An event script: its `data` object.
        if let inner = top["data"]?.object, SkinInputData.keys.allSatisfy({ top[$0] == nil }) { top = inner }
        var d = SkinInputData()
        d.unknownKeys = top.keys.filter { !SkinInputData.keys.contains($0) }.sorted()
        if let v = top["system"] { d.system = try systemFrames(file(v, "system"), "system") }
        if let v = top["battery"] { d.battery = try given(v) { try battery($0, "battery") } }
        if let v = top["sensors"] { (d.sensors, d.thermalState) = try sensors(v, "sensors") }
        if let v = top["nowPlaying"] { d.nowPlaying = try given(v) { try nowPlaying($0, "nowPlaying") } }
        if let v = top["audio"] { d.audio = try given(v) { try audio(file($0, "audio"), "audio") } }
        if let v = top["weather"] { d.weather = try given(v) { try weather($0, "weather") } }
        if let v = top["wifi"] { d.wifi = try given(v) { try wifi($0, "wifi") } }
        if let v = top["desktopImage"] {
            d.desktopImage = try given(v) { v in
                guard let s = v.string, !s.isEmpty else { throw SkinInputDataError("desktopImage", "is not a path") }
                return path(s)
            }
        }
        return d
    }

    // MARK: Helpers

    func path(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL.path
    }

    /// A value, or the path of a JSON file holding it.
    func file(_ v: JSONValue, _ key: String) throws -> JSONValue {
        guard let p = v.string else { return v }
        let url = URL(fileURLWithPath: path(p))
        guard let data = try? Data(contentsOf: url) else { throw SkinInputDataError(key, "cannot read \(url.path)") }
        do { return try JSONValue.parse(data) } catch {
            throw SkinInputDataError(key, "\(url.lastPathComponent) is not JSON")
        }
    }

    func given<T>(_ v: JSONValue, _ read: (JSONValue) throws -> T) rethrows -> SkinInputData.Given<T> {
        v.isNull ? .none : .value(try read(v))
    }

    func object(_ v: JSONValue, _ key: String) throws -> [String: JSONValue] {
        guard let o = v.object else { throw SkinInputDataError(key, "is not an object") }
        return o
    }

    func number(_ v: JSONValue?, _ key: String) throws -> Double? {
        guard let v, !v.isNull else { return nil }
        guard case .number(let n) = v, n.isFinite else { throw SkinInputDataError(key, "is not a number") }
        return n
    }

    func number(_ v: JSONValue?, _ key: String, default d: Double) throws -> Double {
        try number(v, key) ?? d
    }

    func string(_ v: JSONValue?, _ key: String) throws -> String? {
        guard let v, !v.isNull else { return nil }
        guard let s = v.string else { throw SkinInputDataError(key, "is not a string") }
        return s
    }

    func bool(_ v: JSONValue?, _ key: String) throws -> Bool? {
        guard let v, !v.isNull else { return nil }
        guard let b = v.bool else { throw SkinInputDataError(key, "is not true or false") }
        return b
    }

    func numbers(_ v: JSONValue?, _ key: String) throws -> [Double]? {
        guard let v, !v.isNull else { return nil }
        if case .number(let n) = v, n.isFinite { return [n] }
        guard let list = v.array else { throw SkinInputDataError(key, "is not a number or a list of numbers") }
        return try list.enumerated().map { i, e in
            guard let n = try number(e, "\(key)[\(i)]") else { throw SkinInputDataError("\(key)[\(i)]", "is null") }
            return n
        }
    }

    /// A list of numbers for every channel, or one list for all of them.
    func channelLists(_ v: JSONValue?, _ key: String) throws -> [[Double]] {
        guard let v, !v.isNull else { return [] }
        guard let list = v.array else { throw SkinInputDataError(key, "is not a list") }
        if list.allSatisfy({ $0.array != nil }) {
            return try list.enumerated().map { i, e in try numbers(e, "\(key)[\(i)]") ?? [] }
        }
        return [try numbers(v, key) ?? []]
    }

    // MARK: system

    func systemFrames(_ v: JSONValue, _ key: String) throws -> [SkinInputData.SystemFrame] {
        let list: [JSONValue]
        if let a = v.array {
            list = a
        } else if let frames = v["frames"] {
            guard let a = frames.array else { throw SkinInputDataError("\(key).frames", "is not a list") }
            list = a
        } else if v.object != nil {
            list = [v]
        } else {
            throw SkinInputDataError(key, "is not an object, a list of frames or the path of a JSON file")
        }
        guard !list.isEmpty else { throw SkinInputDataError(key, "has no frames") }
        var frames: [SkinInputData.SystemFrame] = []
        var previous = SkinInputData.SystemFrame()
        for (i, f) in list.enumerated() {
            let frame = try systemFrame(f, list.count == 1 && v.array == nil && v["frames"] == nil
                                        ? key : "\(key).frames[\(i)]").over(previous)
            frames.append(frame)
            previous = frame
        }
        return frames
    }

    static let frameKeys: Set<String> = ["cpu", "memory", "network", "bestInterface", "disks", "uptime", "processes",
                                         "sysInfo", "cpuFrequency", "graphicsAdapter"]

    func systemFrame(_ v: JSONValue, _ key: String) throws -> SkinInputData.SystemFrame {
        let o = try object(v, key)
        if let unknown = o.keys.sorted().first(where: { !SkinInputDataReader.frameKeys.contains($0) }) {
            throw SkinInputDataError("\(key).\(unknown)", "is not a system reading (\(SkinInputDataReader.frameKeys.sorted().joined(separator: ", ")))")
        }
        var f = SkinInputData.SystemFrame()
        f.cpu = try numbers(o["cpu"], "\(key).cpu").map { $0.map { min(max($0, 0), 100) } }
        if let m = o["memory"], !m.isNull {
            let mo = try object(m, "\(key).memory")
            f.memory = MemoryStatus(physicalTotal: try number(mo["physicalTotal"], "\(key).memory.physicalTotal", default: 0),
                                    physicalUsed: try number(mo["physicalUsed"], "\(key).memory.physicalUsed", default: 0),
                                    swapTotal: try number(mo["swapTotal"], "\(key).memory.swapTotal", default: 0),
                                    swapUsed: try number(mo["swapUsed"], "\(key).memory.swapUsed", default: 0))
        }
        if let n = o["network"], !n.isNull {
            var counters: [String: NetworkCounters] = [:]
            for (name, c) in try object(n, "\(key).network") {
                let k = "\(key).network.\(name)"
                let co = try object(c, k)
                func count(_ field: String) throws -> UInt64 {
                    let v = try number(co[field], "\(k).\(field)", default: 0)
                    return UInt64(min(max(v, 0), 1.8e19))
                }
                counters[name] = NetworkCounters(received: try count("received"), sent: try count("sent"))
            }
            f.network = counters
        }
        f.bestInterface = try string(o["bestInterface"], "\(key).bestInterface")
        if let d = o["disks"], !d.isNull {
            var disks: [String: SkinInputData.Disk] = [:]
            for (mount, dv) in try object(d, "\(key).disks") {
                let k = "\(key).disks.\(mount)"
                let dobj = try object(dv, k)
                let kindText = try string(dobj["kind"], "\(k).kind") ?? "fixed"
                let kinds: [String: VolumeInfo.Kind] = ["fixed": .fixed, "removable": .removable, "network": .network,
                                                        "cdrom": .cdRom, "ram": .ram]
                guard let kind = kinds[kindText.lowercased()] else {
                    throw SkinInputDataError("\(k).kind", "is not fixed, removable, network, cdrom or ram")
                }
                disks[mount] = SkinInputData.Disk(total: try number(dobj["total"], "\(k).total", default: 0),
                                                  free: try number(dobj["free"], "\(k).free", default: 0),
                                                  available: try number(dobj["available"], "\(k).available"),
                                                  label: try string(dobj["label"], "\(k).label") ?? "", kind: kind)
            }
            f.disks = disks
        }
        f.uptime = try number(o["uptime"], "\(key).uptime")
        if let p = o["processes"], !p.isNull {
            guard let list = p.array else { throw SkinInputDataError("\(key).processes", "is not a list") }
            f.processes = try list.enumerated().map { i, e in
                let k = "\(key).processes[\(i)]"
                let po = try object(e, k)
                guard let name = try string(po["name"], "\(k).name"), !name.isEmpty else {
                    throw SkinInputDataError("\(k).name", "is missing")
                }
                let pid = try number(po["pid"], "\(k).pid", default: Double(1000 + i))
                return SkinInputData.Process(name: name, pid: Int32(min(max(pid, 1), Double(Int32.max))),
                                             cpu: min(max(try number(po["cpu"], "\(k).cpu", default: 0), 0), 100),
                                             memory: max(try number(po["memory"], "\(k).memory", default: 0), 0))
            }
        }
        if let s = o["sysInfo"], !s.isNull {
            var answers: [String: SkinInputData.SysInfoAnswer] = [:]
            for (type, a) in try object(s, "\(key).sysInfo") {
                let k = "\(key).sysInfo.\(type)"
                switch a {
                case .number(let n): answers[type.uppercased()] = .init(number: n, string: nil)
                case .string(let text): answers[type.uppercased()] = .init(number: Double(text) ?? 0, string: text)
                case .object(let ao):
                    answers[type.uppercased()] = .init(number: try number(ao["number"], "\(k).number", default: 0),
                                                       string: try string(ao["string"], "\(k).string"))
                default: throw SkinInputDataError(k, "is not a number, a string or {number, string}")
                }
            }
            f.sysInfo = answers
        }
        f.cpuFrequency = try number(o["cpuFrequency"], "\(key).cpuFrequency")
        f.graphicsAdapter = try string(o["graphicsAdapter"], "\(key).graphicsAdapter")
        return f
    }

    // MARK: battery, sensors

    func battery(_ v: JSONValue, _ key: String) throws -> BatteryStatus {
        let o = try object(v, key)
        let level = min(max(try number(o["level"], "\(key).level", default: 100), 0), 100)
        let charging = try bool(o["charging"], "\(key).charging") ?? false
        let onAC = try bool(o["onAC"], "\(key).onAC") ?? charging
        return BatteryStatus(percent: level, isCharging: charging, isPluggedIn: onAC,
                             minutesRemaining: try number(o["timeRemaining"], "\(key).timeRemaining"))
    }

    func sensors(_ v: JSONValue, _ key: String) throws -> ([String: SkinInputData.Sensor]?, Int?) {
        let o = try object(v, key)
        var list: [String: SkinInputData.Sensor] = [:]
        var thermal: Int?
        for (raw, s) in o {
            let k = "\(key).\(raw)"
            let name = SensorKeys.canonical(raw)
            if MacSensorsMeasure.thermalStateKeys.contains(name) {
                guard let n = try number(s, k) else { continue }
                thermal = Int(min(max(n.rounded(), 0), 3))
                continue
            }
            guard SensorKeys.kind(of: name) != nil else { throw SkinInputDataError(k, "is not a sensor key") }
            switch s {
            case .null: continue
            case .number(let n): list[name] = .init(value: n.isFinite ? n : nil)
            case .object(let so):
                list[name] = .init(value: try number(so["value"], "\(k).value"),
                                   minimum: try number(so["min"], "\(k).min"),
                                   maximum: try number(so["max"], "\(k).max"),
                                   label: try string(so["label"], "\(k).label"))
            default: throw SkinInputDataError(k, "is not a number, null or {value, min, max, label}")
            }
        }
        return (list, thermal)
    }

    // MARK: nowPlaying, audio

    func nowPlaying(_ v: JSONValue, _ key: String) throws -> SkinInputData.NowPlaying {
        let o = try object(v, key)
        let player = (try string(o["player"], "\(key).player") ?? "music").lowercased()
        guard ["music", "itunes", "spotify"].contains(player) else {
            throw SkinInputDataError("\(key).player", "is not music or spotify")
        }
        let stateValue: Int
        switch o["state"] {
        case .string(let s)?:
            let states = ["stopped": 0, "playing": 1, "paused": 2]
            guard let st = states[s.lowercased()] else {
                throw SkinInputDataError("\(key).state", "is not playing, paused or stopped")
            }
            stateValue = st
        case .number(let n)?:
            guard [0, 1, 2].contains(n) else { throw SkinInputDataError("\(key).state", "is not 0, 1 or 2") }
            stateValue = Int(n)
        case nil, .null?:
            stateValue = 1
        default:
            throw SkinInputDataError("\(key).state", "is not playing, paused or stopped")
        }
        let repeatText = try string(o["repeat"], "\(key).repeat")?.lowercased() ?? "off"
        let repeats = ["off": 0, "one": 1, "all": 2]
        guard let repeatMode = repeats[repeatText] else {
            throw SkinInputDataError("\(key).repeat", "is not off, one or all")
        }
        return SkinInputData.NowPlaying(
            player: player == "itunes" ? "music" : player, state: stateValue,
            artist: try string(o["artist"], "\(key).artist") ?? "",
            title: try string(o["title"], "\(key).title") ?? "",
            album: try string(o["album"], "\(key).album") ?? "",
            position: max(try number(o["position"], "\(key).position", default: 0), 0),
            duration: max(try number(o["duration"], "\(key).duration", default: 0), 0),
            cover: try string(o["cover"], "\(key).cover").map(path),
            volume: min(max(try number(o["volume"], "\(key).volume", default: 70), 0), 100),
            shuffle: try bool(o["shuffle"], "\(key).shuffle") ?? false,
            repeatMode: repeatMode,
            rating: min(max(try number(o["rating"], "\(key).rating", default: 0), 0), 100))
    }

    func audio(_ v: JSONValue, _ key: String) throws -> SkinInputData.Audio {
        let o = try object(v, key)
        guard let list = o["frames"]?.array, !list.isEmpty else {
            throw SkinInputDataError("\(key).frames", "is not a list of frames")
        }
        let channels = Int(min(max(try number(o["channels"], "\(key).channels", default: 2), 1), 8))
        func perChannel(_ values: [Double]) -> [Double] {
            values.count == 1 && channels > 1 ? Array(repeating: values[0], count: channels) : values
        }
        func clamp(_ l: [[Double]]) -> [[Double]] { l.map { $0.map { min(max($0, 0), 1) } } }
        let frames = try list.enumerated().map { i, f -> SkinInputData.AudioFrame in
            let k = "\(key).frames[\(i)]"
            let fo = try object(f, k)
            return SkinInputData.AudioFrame(
                rms: perChannel(try numbers(fo["rms"], "\(k).rms") ?? []).map { min(max($0, 0), 1) },
                peak: perChannel(try numbers(fo["peak"], "\(k).peak") ?? []).map { min(max($0, 0), 1) },
                bands: clamp(try channelLists(fo["bands"], "\(k).bands")),
                fft: clamp(try channelLists(fo["fft"], "\(k).fft")))
        }
        return SkinInputData.Audio(frames: frames,
                                   deviceName: try string(o["deviceName"], "\(key).deviceName") ?? "Deskset Test Signal",
                                   sampleRate: max(try number(o["sampleRate"], "\(key).sampleRate", default: 48000), 1),
                                   channels: channels)
    }

    // MARK: weather, wifi

    func weather(_ v: JSONValue, _ key: String) throws -> SkinInputData.Weather {
        var forecastPath: String?
        var status = 200
        var location = SkinInputData.Weather.Location.forecast
        switch v {
        case .string(let p):
            forecastPath = path(p)
        case .object(let o):
            if let f = o["forecast"] {
                if f.isNull { forecastPath = nil } else {
                    guard let p = f.string else { throw SkinInputDataError("\(key).forecast", "is not a path") }
                    forecastPath = path(p)
                }
            } else if o["location"] == nil {
                throw SkinInputDataError(key, "has no forecast")
            }
            status = Int(min(max(try number(o["status"], "\(key).status", default: 200), 100), 599))
            switch o["location"] {
            case nil: break
            case .null?: location = .none
            case .array(let c)? where c.count == 2:
                guard let lat = try number(c[0], "\(key).location[0]"), let lon = try number(c[1], "\(key).location[1]"),
                      (-90...90).contains(lat), (-180...180).contains(lon) else {
                    throw SkinInputDataError("\(key).location", "is not [latitude, longitude]")
                }
                location = .coordinate(latitude: lat, longitude: lon)
            default:
                throw SkinInputDataError("\(key).location", "is not [latitude, longitude] or null")
            }
        default:
            throw SkinInputDataError(key, "is not a path, null or {forecast, location, status}")
        }
        var forecast: Data?
        if let forecastPath {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: forecastPath)) else {
                throw SkinInputDataError(key, "cannot read \(forecastPath)")
            }
            forecast = data
        }
        return SkinInputData.Weather(forecast: forecast, forecastPath: forecastPath, status: status, location: location)
    }

    func wifiNetwork(_ v: JSONValue, _ key: String) throws -> SkinInputData.WiFiNetwork {
        let o = try object(v, key)
        return SkinInputData.WiFiNetwork(
            ssid: try string(o["ssid"], "\(key).ssid") ?? "",
            rssi: Int(min(max(try number(o["rssi"], "\(key).rssi", default: 0), -200), 0)),
            transmitRate: max(try number(o["transmitRate"], "\(key).transmitRate", default: 0), 0),
            encryption: try string(o["encryption"], "\(key).encryption") ?? "AES",
            auth: try string(o["auth"], "\(key).auth") ?? "WPA2-Personal",
            phy: try string(o["phy"], "\(key).phy") ?? "802.11ax")
    }

    func wifi(_ v: JSONValue, _ key: String) throws -> SkinInputData.WiFi {
        let o = try object(v, key)
        let current = try wifiNetwork(v, key)
        var networks: [SkinInputData.WiFiNetwork] = []
        if let n = o["networks"], !n.isNull {
            guard let list = n.array else { throw SkinInputDataError("\(key).networks", "is not a list") }
            networks = try list.enumerated().map { i, e in try wifiNetwork(e, "\(key).networks[\(i)]") }
        }
        return SkinInputData.WiFi(current: current, networks: networks)
    }
}
