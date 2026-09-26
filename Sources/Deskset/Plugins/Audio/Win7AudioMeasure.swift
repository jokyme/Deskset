import CoreAudio
import Foundation
import DesksetCore

// `Measure=Plugin`, `Plugin=Win7AudioPlugin` (manual: https://docs.rainmeter.net/manual/plugins/win7audio/),
// backed by the default Core Audio output device.
//
// - Number: the volume 0…100 (rounded to a whole percent), -1 while muted (the manual only says 0–100, but skins
//   test `MeasureVolume < 0` / Substitute "-1":"Muted" for the muted state, so the observed convention is kept).
//   A device without a volume control (HDMI, some USB DACs) reads 100.
// - String: the device name; "ERROR - Getting Default Device" when there is no output device.
// - Commands (!CommandMeasure): ToggleNext, TogglePrevious, SetOutputIndex n (1 = first output device),
//   ToggleMute, SetVolume x (0…100, unmutes), ChangeVolume ±x (unmutes); Mute and Unmute are accepted too.
//   Device order is Core Audio's; only devices that can be the default output count.

/// A Win7Audio command.
enum Win7AudioCommand: Equatable {
    case toggleNext
    case togglePrevious
    case setOutputIndex(Int)
    case toggleMute
    case mute
    case unmute
    case setVolume(Double)
    case changeVolume(Double)

    /// `ChangeVolume +5`, `SetVolume 50`, `SetOutputIndex 2` (case-insensitive); nil when unknown or when a number
    /// is missing.
    static func parse(_ text: String) -> Win7AudioCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = parts.first else { return nil }
        let argument = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        func number() -> Double? {
            if let v = Double(argument), v.isFinite { return v }
            guard let v = OptionValue.number(argument), v.isFinite else { return nil }
            return v
        }
        switch first.lowercased() {
        case "togglenext": return .toggleNext
        case "toggleprevious": return .togglePrevious
        case "togglemute": return .toggleMute
        case "mute": return .mute
        case "unmute": return .unmute
        case "setvolume": return number().map { .setVolume($0) }
        case "changevolume": return number().map { .changeVolume($0) }
        case "setoutputindex": return number().map { .setOutputIndex(Int($0.rounded(.towardZero).clamped(-1e9, 1e9))) }
        default: return nil
        }
    }

    /// Carries the command out; returns a message to log when it cannot.
    func apply(to system: AudioOutputControlling) -> String? {
        let snapshot = system.snapshot()
        let output = snapshot.output
        switch self {
        case .toggleMute, .mute, .unmute:
            guard output.deviceID != nil else { return "there is no audio output device" }
            guard output.canMute || output.canSetVolume else { return "the output device cannot be muted" }
            system.setOutputMuted(self == .toggleMute ? !output.muted : self == .mute)
        case .setVolume(let v):
            guard output.canSetVolume else { return "the output device has no volume control" }
            system.setOutputVolume(v.clamped(0, 100) / 100)
        case .changeVolume(let delta):
            guard output.canSetVolume else { return "the output device has no volume control" }
            let current = (output.volume ?? 1) * 100
            system.setOutputVolume((current + delta).clamped(0, 100) / 100)
        case .toggleNext, .togglePrevious:
            let devices = snapshot.outputDevices
            guard !devices.isEmpty else { return "there is no audio output device" }
            let index = devices.firstIndex { $0.id == snapshot.defaultOutput }
            let next: Int
            if let index {
                next = self == .toggleNext ? (index + 1) % devices.count : (index - 1 + devices.count) % devices.count
            } else {
                next = self == .toggleNext ? 0 : devices.count - 1
            }
            if devices[next].id != snapshot.defaultOutput { system.setDefaultOutput(devices[next].id) }
        case .setOutputIndex(let n):
            let devices = snapshot.outputDevices
            guard n >= 1, n <= devices.count else {
                return "SetOutputIndex \(n): there \(devices.count == 1 ? "is 1 output device" : "are \(devices.count) output devices")"
            }
            system.setDefaultOutput(devices[n - 1].id)
        }
        return nil
    }
}

final class Win7AudioMeasure: Measure {
    /// Replaced in tests.
    var system: AudioOutputControlling = AudioSystem.shared
    private(set) var pluginString: String?

    required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
    }

    override var automaticMaxValue: Double { 100 }

    override func computeValue() -> Double {
        let result = Win7AudioMeasure.values(system.snapshot())
        pluginString = result.text
        setPluginString(result.text)
        return result.number
    }

    /// Number and string for a snapshot (see the file comment).
    static func values(_ s: AudioSystemSnapshot) -> (number: Double, text: String) {
        guard s.loaded else { return (0, "") }
        guard s.output.deviceID != nil else { return (0, "ERROR - Getting Default Device") }
        if s.output.muted { return (-1, s.output.name) }
        return (((s.output.volume ?? 1) * 100).rounded(), s.output.name)
    }

    override func execute(command: String) {
        guard let parsed = Win7AudioCommand.parse(command) else {
            skin.log("[\(name)] Win7Audio: unknown command \"\(command)\"", level: .warning)
            return
        }
        if let problem = parsed.apply(to: system) {
            skin.log("[\(name)] Win7Audio: \(problem)", level: .notice)
        }
    }
}

extension Double {
    /// NaN → lo (same contract as the engine's helper, which is internal to DesksetCore).
    fileprivate func clamped(_ lo: Double, _ hi: Double) -> Double {
        isNaN ? lo : Swift.min(Swift.max(self, lo), hi)
    }
}
