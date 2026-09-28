import CoreAudio
import Foundation
import DesksetCore

// The audio plugins' part of a skin's side effects (the engine's SideEffects.swift): what Win7Audio and AppVolume
// change on the Mac goes through `skin.sideEffects.perform`, which does it (live) or only records it as an
// `AudioEffect` (a recording). The Core Audio calls that change a device are here, the live half of those effects.

extension Win7AudioCommand {
    /// The command as a skin's side effect.
    var effect: AudioEffect {
        switch self {
        case .toggleNext: return .nextOutput
        case .togglePrevious: return .previousOutput
        case .setOutputIndex(let n): return .selectOutput(n)
        case .toggleMute: return .toggleMute
        case .mute: return .mute
        case .unmute: return .unmute
        case .setVolume(let v): return .setVolume(v)
        case .changeVolume(let v): return .changeVolume(v)
        }
    }
}

extension AudioHAL {
    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        return withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    static func setDefaultOutputDevice(_ id: AudioObjectID) -> OSStatus {
        set(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    @discardableResult
    static func setVolume(_ device: AudioObjectID, _ value: Double) -> OSStatus {
        set(device, volumeAddress, Float32(min(max(value, 0), 1)))
    }

    @discardableResult
    static func setMute(_ device: AudioObjectID, _ muted: Bool) -> OSStatus {
        set(device, muteAddress, UInt32(muted ? 1 : 0))
    }
}
