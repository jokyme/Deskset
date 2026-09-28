import AppKit
import CoreAudio
import DesksetCore

// The media plugins' part of a skin's side effects (the engine's SideEffects.swift): what NowPlaying, iTunes,
// WebNowPlaying and MediaKey do outside the skin — commands to Music and Spotify, opening a player, media-key events and
// the volume keys — goes through `skin.sideEffects.perform`, which does it (live) or only records it (a recording). The
// calls that post a key event, change the output volume or open a player are here, the live half of those effects.
// (The AppleScript runner in NowPlayingCenter.swift both reads the players' state and sends their commands; the
// commands are gated in the measures.)

extension MediaKeyCommand {
    /// The manual's name of the key (`PlayPause`), for the record of a skin's side effects.
    var manualName: String {
        switch self {
        case .nextTrack: return "NextTrack"
        case .prevTrack: return "PrevTrack"
        case .stop: return "Stop"
        case .playPause: return "PlayPause"
        case .volumeMute: return "VolumeMute"
        case .volumeDown: return "VolumeDown"
        case .volumeUp: return "VolumeUp"
        }
    }
}

extension NowPlayingCenter {
    /// Opens a player that is not running (OpenPlayer, TogglePlayer).
    static func launchPlayer(at url: URL) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Media-key events (the same events the keyboard's media keys produce).
enum MediaKeys {
    /// Posting keyboard events needs the Accessibility permission; checked without asking.
    static var canPostEvents: Bool { AXIsProcessTrusted() }

    /// NX key types (IOKit ev_keymap.h): sound up 0, sound down 1, mute 7, play 16, next 17, previous 18.
    static func keyType(_ key: MediaKeyCommand) -> Int32 {
        switch key {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .volumeMute: return 7
        case .playPause, .stop: return 16   // .stop is never posted (see MediaKeyMeasure)
        case .nextTrack: return 17
        case .prevTrack: return 18
        }
    }

    /// Posts the key's down and up events: built on the main thread (an `NSEvent`), at once when the caller is there,
    /// else queued there.
    static func post(_ key: MediaKeyCommand) {
        MediaUIMainHop.run { postOnMain(key) }
    }

    private static func postOnMain(_ key: MediaKeyCommand) {
        let type = keyType(key)
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((type << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Volume of the default output device (CoreAudio; no permission needed). `change(by:)` and `toggleMute()` run on a
/// serial background queue: HAL calls are requests to the audio server and can stall (Bluetooth / AirPlay devices
/// switching), which must never freeze the skins.
enum MediaUISystemVolume {
    private static let queue = DispatchQueue(label: "Deskset MediaKey volume", qos: .userInitiated)

    private static func run(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                                                &device)
        return status == noErr && device != 0 ? device : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    /// "Virtual main volume" ('vmvc', AudioHardwareService): the volume the menu bar slider shows.
    private static let virtualMainVolume: AudioObjectPropertySelector = 0x766D_7663

    static func volume() -> Float? {
        guard let device = defaultOutputDevice() else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = address(virtualMainVolume)
        guard AudioObjectHasProperty(device, &a),
              AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func change(by delta: Float) {
        run {
            guard delta.isFinite, let device = defaultOutputDevice(), let current = volume() else { return }
            var value = Float32(min(max(current + delta, 0), 1))
            var a = address(virtualMainVolume)
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue else { return }
            AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
            if value > 0 { setMute(device, false) }
        }
    }

    static func toggleMute() {
        run {
            guard let device = defaultOutputDevice() else { return }
            var muted = UInt32(0)
            var size = UInt32(MemoryLayout<UInt32>.size)
            var a = address(kAudioDevicePropertyMute)
            guard AudioObjectHasProperty(device, &a),
                  AudioObjectGetPropertyData(device, &a, 0, nil, &size, &muted) == noErr else { return }
            setMute(device, muted == 0)
        }
    }

    private static func setMute(_ device: AudioDeviceID, _ on: Bool) {
        var value = UInt32(on ? 1 : 0)
        var a = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &a) else { return }
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
}
