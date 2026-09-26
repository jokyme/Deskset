import AudioToolbox
import CoreAudio
import Foundation

/// Thin Core Audio (HAL) helpers. Property reads are IPC calls to coreaudiod that normally take microseconds but can
/// stall while devices change, so every caller runs on `AudioHAL.queue` — never on the main thread. Skins read the
/// cached results (`AudioSystem`).
enum AudioHAL {
    /// Serial queue for all HAL calls and capture start/stop.
    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "net.deskset.audio.hal", qos: .userInitiated)
        q.setSpecific(key: queueKey, value: true)
        return q
    }()
    private static let queueKey = DispatchSpecificKey<Bool>()
    /// True on `queue` (waiting for it there would deadlock).
    static var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == true }
    /// UID prefix of Deskset's own private aggregate devices (hidden from device lists).
    static let ownDevicePrefix = "net.deskset.audio."

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(object, &a)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &a, &settable) == noErr && settable.boolValue
    }

    /// A fixed-size property value.
    static func get<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type) -> T? {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw) == noErr,
              size == UInt32(MemoryLayout<T>.size) else { return nil }
        return raw.load(as: T.self)
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        return withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    /// A CFString property (name, UID…); the HAL hands out a retained string.
    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// An array of fixed-size elements (device lists, process lists).
    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of type: T.Type) -> [T] {
        var a = address
        guard AudioObjectHasProperty(object, &a) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0, count < 100_000 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw) == noErr else { return [] }
        let n = min(count, Int(size) / MemoryLayout<T>.stride)
        let typed = raw.bindMemory(to: T.self, capacity: n)
        return Array(UnsafeBufferPointer(start: typed, count: n))
    }

    // MARK: Devices

    static func deviceIDs() -> [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
    }

    static func defaultDevice(input: Bool) -> AudioObjectID? {
        let selector = input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        guard let id = get(AudioObjectID(kAudioObjectSystemObject), address(selector), as: AudioObjectID.self),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func setDefaultOutputDevice(_ id: AudioObjectID) -> OSStatus {
        set(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), id)
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(device, address(kAudioDevicePropertyDeviceUID))
    }

    static func name(of device: AudioObjectID) -> String? {
        string(device, address(kAudioObjectPropertyName)) ?? string(device, address(kAudioDevicePropertyDeviceNameCFString))
    }

    static func device(withUID uid: String) -> AudioObjectID? {
        deviceIDs().first { self.uid(of: $0) == uid }
    }

    /// Channels of all input (or output) streams.
    static func channelCount(of device: AudioObjectID, input: Bool) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration,
                        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &a, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size), size < 1_000_000 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func nominalSampleRate(of device: AudioObjectID) -> Double? {
        get(device, address(kAudioDevicePropertyNominalSampleRate), as: Float64.self).flatMap { $0 > 0 ? $0 : nil }
    }

    static func canBeDefault(_ device: AudioObjectID, input: Bool) -> Bool {
        let a = address(kAudioDevicePropertyDeviceCanBeDefaultDevice,
                        input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        return (get(device, a, as: UInt32.self) ?? 1) != 0
    }

    static func isHidden(_ device: AudioObjectID) -> Bool {
        (get(device, address(kAudioDevicePropertyIsHidden), as: UInt32.self) ?? 0) != 0
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        (get(device, address(kAudioDevicePropertyDeviceIsAlive), as: UInt32.self) ?? 0) != 0
    }

    /// Virtual format of the first input stream (the format IOProcs see), or the device's stream format.
    static func inputStreamFormat(of device: AudioObjectID) -> AudioStreamBasicDescription? {
        let streams = array(device, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput),
                            of: AudioObjectID.self)
        if let first = streams.first,
           let f = get(first, address(kAudioStreamPropertyVirtualFormat), as: AudioStreamBasicDescription.self) {
            return f
        }
        return get(device, address(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeInput),
                   as: AudioStreamBasicDescription.self)
    }

    // MARK: Volume and mute (output scope)

    static let volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       kAudioObjectPropertyScopeOutput)
    static let muteAddress = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)

    /// 0…1, or nil when the device has no volume control (HDMI, some USB devices).
    static func volume(of device: AudioObjectID) -> Double? {
        get(device, volumeAddress, as: Float32.self).map { Double(min(max($0, 0), 1)) }
    }

    static func hasSettableVolume(_ device: AudioObjectID) -> Bool {
        has(device, volumeAddress) && isSettable(device, volumeAddress)
    }

    @discardableResult
    static func setVolume(_ device: AudioObjectID, _ value: Double) -> OSStatus {
        set(device, volumeAddress, Float32(min(max(value, 0), 1)))
    }

    static func isMuted(_ device: AudioObjectID) -> Bool? {
        get(device, muteAddress, as: UInt32.self).map { $0 != 0 }
    }

    static func hasSettableMute(_ device: AudioObjectID) -> Bool {
        has(device, muteAddress) && isSettable(device, muteAddress)
    }

    @discardableResult
    static func setMute(_ device: AudioObjectID, _ muted: Bool) -> OSStatus {
        set(device, muteAddress, UInt32(muted ? 1 : 0))
    }

    // MARK: Listeners

    /// Adds a block listener on `queue`; returns a token that removes it.
    static func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, queue: DispatchQueue,
                       _ handler: @escaping () -> Void) -> AudioListenerToken? {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &a, queue, block) == noErr else { return nil }
        return AudioListenerToken(object: object, address: address, queue: queue, block: block)
    }

    // MARK: Formatting

    /// `Type=Format`: e.g. "48000 Hz, 32-bit float, 2 channels".
    static func describe(sampleRate: Double, bitsPerChannel: Int, isFloat: Bool, channels: Int) -> String {
        guard sampleRate > 0, channels > 0 else { return "" }
        let rate = sampleRate == sampleRate.rounded() ? String(Int(sampleRate)) : String(format: "%.1f", sampleRate)
        let bits = bitsPerChannel > 0 ? "\(bitsPerChannel)-bit \(isFloat ? "float" : "integer"), " : ""
        return "\(rate) Hz, \(bits)\(channels) channel\(channels == 1 ? "" : "s")"
    }
}

/// Removes its property listener when released (or on `remove()`).
final class AudioListenerToken {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue,
         block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }

    func remove() {
        guard let block else { return }
        var a = address
        AudioObjectRemovePropertyListenerBlock(object, &a, queue, block)
        self.block = nil
    }

    deinit { remove() }
}
