import Foundation
import DesksetCore

// `Measure=Plugin`, `Plugin=AudioLevel` (manual: https://docs.rainmeter.net/manual/plugins/audiolevel/).
//
// - A measure without `Parent=` is a parent: it reads Port, ID and the RMS/Peak/FFT/Bands options once (the manual:
//   parent options "may not be changed dynamically") and, at its first update in a skin window, subscribes an
//   analyzer to the shared capture engine (reading a skin's options never starts a capture: see
//   `AudioPlugins.mayCapture(for:)`). Its own value is 0 unless it also has a `Type=` (then it answers like a
//   child of itself).
// - A child (`Parent=Name`) reads Type, Channel, FFTIdx and BandIdx on every option read (these may change with
//   !SetOption / DynamicVariables) and asks its parent's analyzer. Children and parents live in the same skin.
// - Values: RMS, Peak, FFT, Band 0…1; FFTFreq / BandFreq in Hz; DeviceStatus 1 / 0. Format, DeviceName,
//   DeviceID and DeviceList are strings (number 0). Device IDs are Core Audio UIDs (e.g. "BuiltInSpeakerDevice");
//   a Windows ID ({0.0.0.00000000}.{…}) matches nothing and falls back to the default device.

/// `Type=` of an AudioLevel measure.
enum AudioLevelType: String, CaseIterable {
    case rms, peak, fft, fftFreq = "fftfreq", band, bandFreq = "bandfreq", format, deviceStatus = "devicestatus"
    case deviceName = "devicename", deviceID = "deviceid", deviceList = "devicelist"

    static func parse(_ raw: String) -> AudioLevelType? {
        AudioLevelType(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Types whose value is a string (the number is 0).
    var isString: Bool {
        switch self {
        case .format, .deviceName, .deviceID, .deviceList: return true
        default: return false
        }
    }
}

/// Parent options (read once).
struct AudioLevelParentOptions: Equatable {
    var port = AudioSourceKind.output
    var deviceID: String?
    var analysis = AudioAnalysisSettings()
    /// `Port=` had a value other than Output / Input (Output is used).
    var invalidPort: String?

    var sourceKey: AudioSourceKey { AudioSourceKey(kind: port, deviceID: deviceID) }

    /// `option(key)` returns the resolved option text or nil.
    static func read(_ option: (String) -> String?) -> AudioLevelParentOptions {
        var o = AudioLevelParentOptions()
        let port = (option("Port") ?? "").trimmingCharacters(in: .whitespaces)
        switch port.lowercased() {
        case "", "output": o.port = .output
        case "input": o.port = .input
        default: o.invalidPort = port
        }
        let id = (option("ID") ?? "").trimmingCharacters(in: .whitespaces)
        o.deviceID = id.isEmpty ? nil : id
        func number(_ key: String, _ d: Double) -> Double {
            guard let s = option(key), !s.trimmingCharacters(in: .whitespaces).isEmpty else { return d }
            return OptionValue.number(s) ?? d
        }
        func integer(_ key: String) -> Int {
            let v = number(key, 0)
            return v.isFinite ? Int(max(min(v, 1e9), -1e9)) : 0
        }
        var a = AudioAnalysisSettings()
        a.rmsAttack = number("RMSAttack", 300)
        a.rmsDecay = number("RMSDecay", 300)
        a.rmsGain = number("RMSGain", 1)
        a.peakAttack = number("PeakAttack", 50)
        a.peakDecay = number("PeakDecay", 2500)
        a.peakGain = number("PeakGain", 1)
        a.fftSize = integer("FFTSize")
        a.fftOverlap = integer("FFTOverlap")
        a.fftAttack = number("FFTAttack", 300)
        a.fftDecay = number("FFTDecay", 300)
        a.bands = integer("Bands")
        a.freqMin = number("FreqMin", 20)
        a.freqMax = number("FreqMax", 20000)
        a.sensitivity = number("Sensitivity", 35)
        o.analysis = a.normalized()
        return o
    }
}

/// Child options (dynamic).
struct AudioLevelChildOptions: Equatable {
    var type: AudioLevelType?
    /// `Type=` as written when it is not a known type.
    var invalidType: String?
    var channel = AudioChannel.sum
    var invalidChannel: String?
    var fftIndex = 0
    var bandIndex = 0

    static func read(_ option: (String) -> String?) -> AudioLevelChildOptions {
        var o = AudioLevelChildOptions()
        let type = (option("Type") ?? "").trimmingCharacters(in: .whitespaces)
        if !type.isEmpty {
            o.type = AudioLevelType.parse(type)
            if o.type == nil { o.invalidType = type }
        }
        let channel = option("Channel") ?? ""
        if let c = AudioChannel.parse(channel) {
            o.channel = c
        } else {
            o.invalidChannel = channel.trimmingCharacters(in: .whitespaces)
        }
        func index(_ key: String) -> Int {
            guard let s = option(key), let v = OptionValue.number(s), v.isFinite else { return 0 }
            return Int(max(min(v, 1e9), -1e9))
        }
        o.fftIndex = index("FFTIdx")
        o.bandIndex = index("BandIdx")
        return o
    }
}

final class AudioLevelMeasure: Measure {
    /// Parent options, set by the first option read of a measure without `Parent=`.
    private(set) var parentOptions: AudioLevelParentOptions?
    private(set) var analyzer: AudioAnalyzer?
    private(set) var parentName = ""
    private(set) var child = AudioLevelChildOptions()
    /// The string value (Format, DeviceName, DeviceID, DeviceList); see `setPluginString`.
    private(set) var pluginString: String?

    /// Replaced in tests.
    var engine = AudioCaptureEngine.shared
    /// The audio devices (tests replace it): `sharedSystem`, looked up at every read.
    var system: () -> AudioSystemSnapshot = { AudioLevelMeasure.sharedSystem() }
    /// Where every AudioLevel measure reads the audio devices unless its own `system` is replaced. The app never
    /// changes it; the app self-tests (their skins update on the main thread) put a fake device here for a suite, so
    /// all measures — also those a skin refresh creates — see the same devices on every Mac.
    static var sharedSystem: () -> AudioSystemSnapshot = { AudioSystem.shared.snapshot() }
    /// Reads the device list before the capture starts, so the first update already knows device names (tests
    /// replace it).
    var prepareSystem: () -> Void = { AudioSystem.shared.activateIfNeeded() }
    /// Whether the skin may capture (tests replace it): see `AudioPlugins.mayCapture(for:)`.
    var mayCapture: (Skin) -> Bool = { AudioPlugins.mayCapture(for: $0) }
    /// Finds the parent measure (the skin's measure of that name; tests replace it).
    var parentLookup: ((String) -> AudioLevelMeasure?)?
    /// The parent's analyzer is subscribed to `engine` (see `subscribeIfNeeded`).
    private(set) var subscribed = false
    private var loggedMessages: Set<String> = []
    /// The permission note this parent last added to its skin (taken back when it no longer applies).
    private var notedPermission: String?

    required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
    }

    deinit {
        if subscribed, let analyzer { engine.unsubscribe(analyzer) }
    }

    override var automaticMaxValue: Double {
        switch child.type {
        case .fftFreq?: return max(sourceSampleRate() / 2, 1)
        case .bandFreq?: return parentMeasure()?.parentOptions?.analysis.freqMax ?? 1
        default: return 1
        }
    }

    override func readMeasureOptions() {
        parentName = string("Parent").trimmingCharacters(in: .whitespaces)
        if parentName.isEmpty && parentOptions == nil { configureParent() }
        let options = AudioLevelChildOptions.read { self.option($0) }
        if let t = options.invalidType { logOnce("[\(name)] AudioLevel: unknown Type=\(t)", level: .warning) }
        if let c = options.invalidChannel { logOnce("[\(name)] AudioLevel: unknown Channel=\(c); using Sum", level: .warning) }
        child = options
    }

    private func configureParent() {
        let options = AudioLevelParentOptions.read { self.option($0) }
        parentOptions = options
        if let p = options.invalidPort {
            logOnce("[\(name)] AudioLevel: unknown Port=\(p); using Output", level: .warning)
        }
        analyzer = AudioAnalyzer(settings: options.analysis)
    }

    /// Subscribes a parent's analyzer at the parent's first update, not when its options are read: the Manage window
    /// reads the options of skins that are not loaded (their compatibility notes), and that must not start a capture.
    /// A skin outside a skin window never captures (`mayCapture`).
    private func subscribeIfNeeded() {
        guard !subscribed, let options = parentOptions, let analyzer else { return }
        guard mayCapture(skin) else {
            logOnce("[\(name)] AudioLevel: no capture outside a skin window "
                    + "(DESKSET_AUDIO_DEMO=1 plays a demo signal)", level: .notice)
            return
        }
        subscribed = true
        prepareSystem()
        engine.subscribe(analyzer, to: options.sourceKey)
    }

    override func computeValue() -> Double {
        subscribeIfNeeded()
        if child.type == .fft { parentMeasure()?.analyzer?.requestBinValues() }
        // The parent reports why its stream does not run (once); children stay quiet. A refused permission is
        // also a compatibility note of the skin (the Mac asks for one; Windows does not), taken back once it no
        // longer applies (the permission was granted, sound arrived after the silence watchdog's note). Another
        // parent still reporting the same note adds it again at its next update.
        if subscribed, let options = parentOptions {
            let status = engine.status(for: options.sourceKey)
            if let message = status.message, message != "starting" {
                logOnce("[\(name)] AudioLevel: \(message)", level: .notice)
            }
            if let old = notedPermission, old != status.permissionNote { skin.removeIssue(old) }
            if let note = status.permissionNote { skin.addIssue(note) }
            notedPermission = status.permissionNote
        }
        let result = evaluate()
        pluginString = result.text
        setPluginString(result.text)
        return result.number.isFinite ? result.number : 0
    }

    // MARK: Evaluation

    /// The parent measure whose analyzer this measure reads (itself for a parent).
    func parentMeasure() -> AudioLevelMeasure? {
        if parentName.isEmpty { return parentOptions == nil ? nil : self }
        if let parentLookup { return parentLookup(parentName) }
        return skin.measure(named: parentName) as? AudioLevelMeasure
    }

    private func sourceSampleRate() -> Double {
        guard let parent = parentMeasure(), let options = parent.parentOptions else { return 48000 }
        let status = engine.status(for: options.sourceKey)
        if status.sampleRate > 0 { return status.sampleRate }
        if let analyzerRate = parent.analyzer?.format.sampleRate, analyzerRate > 0 { return analyzerRate }
        return AudioLevelMeasure.device(for: options.sourceKey, in: system())?.sampleRate ?? 48000
    }

    func evaluate() -> (number: Double, text: String?) {
        guard let type = child.type else { return (0, nil) }
        let empty: String? = type.isString ? "" : nil
        guard let parent = parentMeasure() else {
            if parentName.isEmpty { return (0, empty) }
            logOnce("[\(name)] AudioLevel: Parent=\(parentName) is not an AudioLevel parent measure", level: .warning)
            return (0, empty)
        }
        guard let options = parent.parentOptions, let analyzer = parent.analyzer else {
            // A parent that is disabled since the skin loaded has not read its options yet: silent 0.
            if !parent.parentName.isEmpty {
                logOnce("[\(name)] AudioLevel: Parent=\(parentName) is itself a child measure", level: .warning)
            }
            return (0, empty)
        }
        let key = options.sourceKey
        let status = engine.status(for: key)
        switch type {
        case .rms:
            return (analyzer.rms(child.channel), nil)
        case .peak:
            return (analyzer.peak(child.channel), nil)
        case .fft:
            if options.analysis.fftSize == 0 {
                logOnce("[\(name)] AudioLevel: Type=FFT needs FFTSize on [\(parent.name)]", level: .warning)
            }
            return (analyzer.fft(child.channel, index: child.fftIndex), nil)
        case .band:
            if options.analysis.fftSize == 0 || options.analysis.bands == 0 {
                logOnce("[\(name)] AudioLevel: Type=Band needs FFTSize and Bands on [\(parent.name)]", level: .warning)
            }
            return (analyzer.band(child.channel, index: child.bandIndex), nil)
        case .fftFreq:
            return (analyzer.fftFrequency(index: child.fftIndex, sampleRate: sourceSampleRate()), nil)
        case .bandFreq:
            return (analyzer.bandFrequency(index: child.bandIndex), nil)
        case .deviceStatus:
            return (status.running ? 1 : 0, nil)
        case .format:
            if !status.format.isEmpty { return (0, status.format) }
            // Not capturing: the device's nominal format (bit depth unknown).
            guard let d = AudioLevelMeasure.device(for: key, in: system()) else { return (0, "") }
            let channels = options.port == .input ? d.inputChannels : d.outputChannels
            return (0, AudioHAL.describe(sampleRate: d.sampleRate, bitsPerChannel: 0, isFloat: true, channels: channels))
        case .deviceName:
            if !status.deviceName.isEmpty { return (0, status.deviceName) }
            return (0, AudioLevelMeasure.device(for: key, in: system())?.name ?? "")
        case .deviceID:
            if !status.deviceUID.isEmpty { return (0, status.deviceUID) }
            return (0, AudioLevelMeasure.device(for: key, in: system())?.uid ?? "")
        case .deviceList:
            let snapshot = system()
            let devices = options.port == .input ? snapshot.inputDevices : snapshot.outputDevices
            return (0, AudioLevelMeasure.deviceList(devices))
        }
    }

    /// `Type=DeviceList`: one device per line, `UID: Name`, in system order.
    static func deviceList(_ devices: [AudioDeviceInfo]) -> String {
        devices.map { "\($0.uid): \($0.name)" }.joined(separator: "\n")
    }

    /// The device a key names in a snapshot (UID, then name, else the default device of its port).
    static func device(for key: AudioSourceKey, in snapshot: AudioSystemSnapshot) -> AudioDeviceInfo? {
        let input = key.kind == .input
        let candidates = input ? snapshot.inputDevices : snapshot.outputDevices
        if let id = key.deviceID {
            if let d = candidates.first(where: { $0.uid == id }) { return d }
            if let d = candidates.first(where: { $0.name.caseInsensitiveCompare(id) == .orderedSame }) { return d }
        }
        return snapshot.device(input ? snapshot.defaultInput : snapshot.defaultOutput)
    }

    private func logOnce(_ message: String, level: SkinLogLevel) {
        guard loggedMessages.count < 50, loggedMessages.insert(message).inserted else { return }
        skin.log(message, level: level)
    }
}
