import CoreAudio
import Foundation

/// One audio device as skins see it.
struct AudioDeviceInfo: Equatable {
    var id: AudioObjectID
    /// Core Audio UID: Deskset's device "ID" (AudioLevel `ID=`, `Type=DeviceID` / `DeviceList`).
    var uid: String
    var name: String
    var inputChannels: Int
    var outputChannels: Int
    var sampleRate: Double
    var canBeDefaultOutput: Bool
    var canBeDefaultInput: Bool
}

/// The default output device's volume state (Win7Audio).
struct AudioOutputState: Equatable {
    var deviceID: AudioObjectID?
    var name = ""
    /// 0…1; nil when the device has no volume control (HDMI, some USB devices): audio plays at full level.
    var volume: Double?
    var muted = false
    var canSetVolume = false
    /// Hardware mute control (otherwise mute is emulated with the volume).
    var canMute = false
}

struct AudioSystemSnapshot {
    /// False until the first read of the devices has finished.
    var loaded = false
    /// Visible devices in system order (Deskset's own capture devices and hidden devices left out).
    var devices: [AudioDeviceInfo] = []
    var defaultOutput: AudioObjectID?
    var defaultInput: AudioObjectID?
    var output = AudioOutputState()

    /// Devices that can be the default output (Win7Audio ToggleNext / SetOutputIndex), in system order.
    var outputDevices: [AudioDeviceInfo] { devices.filter { $0.outputChannels > 0 && $0.canBeDefaultOutput } }
    var inputDevices: [AudioDeviceInfo] { devices.filter { $0.inputChannels > 0 && $0.canBeDefaultInput } }

    func device(_ id: AudioObjectID?) -> AudioDeviceInfo? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }
}

/// Volume and device control used by Win7Audio (a fake replaces it in tests).
protocol AudioOutputControlling: AnyObject {
    func snapshot() -> AudioSystemSnapshot
    /// 0…1; also unmutes ("SetVolume … disables mute").
    func setOutputVolume(_ volume: Double)
    func setOutputMuted(_ muted: Bool)
    func setDefaultOutput(_ device: AudioObjectID)
    /// Changes the volume by `delta` percentage points (the result clamped to 0…100 %) from the current one, and
    /// unmutes, as one step: two skins changing it at the same time both count.
    func changeOutputVolume(byPercent delta: Double)
    /// Mutes when unmuted and the other way round, as one step: two toggles at the same time cancel out.
    func toggleOutputMuted()
}

extension AudioOutputControlling {
    /// Read, then write (fakes that only one thread uses).
    func changeOutputVolume(byPercent delta: Double) {
        setOutputVolume(AudioSystem.changedVolume(snapshot().output.volume, byPercent: delta))
    }

    func toggleOutputMuted() {
        setOutputMuted(!snapshot().output.muted)
    }
}

/// The Core Audio calls `AudioSystem` makes, always on `AudioHAL.queue`. The self-tests use a fake, so they can check
/// command handling without ever reading or changing the Mac's real volume.
protocol AudioSystemHAL: AnyObject {
    /// Visible devices in system order (Deskset's own capture devices and hidden devices left out).
    func devices() -> [AudioDeviceInfo]
    func defaultDevice(input: Bool) -> AudioObjectID?
    func name(of device: AudioObjectID) -> String?
    /// 0…1, nil without a volume control.
    func volume(of device: AudioObjectID) -> Double?
    func isMuted(_ device: AudioObjectID) -> Bool?
    func hasSettableVolume(_ device: AudioObjectID) -> Bool
    func hasSettableMute(_ device: AudioObjectID) -> Bool
    func setVolume(_ device: AudioObjectID, _ value: Double)
    func setMute(_ device: AudioObjectID, _ muted: Bool)
    func setDefaultOutputDevice(_ device: AudioObjectID) -> OSStatus
    /// Calls `handler` on `AudioHAL.queue` when the device list or a default device changes.
    func listenToSystem(_ handler: @escaping () -> Void) -> [AudioListenerToken]
    /// Calls `handler` on `AudioHAL.queue` when the volume or the mute state of `device` changes.
    func listenToOutput(_ device: AudioObjectID, _ handler: @escaping () -> Void) -> [AudioListenerToken]
}

/// The real HAL.
final class CoreAudioSystemHAL: AudioSystemHAL {
    func devices() -> [AudioDeviceInfo] {
        AudioHAL.deviceIDs().compactMap { id in
            guard let uid = AudioHAL.uid(of: id), !uid.hasPrefix(AudioHAL.ownDevicePrefix),
                  !AudioHAL.isHidden(id) else { return nil }
            return AudioDeviceInfo(
                id: id, uid: uid, name: AudioHAL.name(of: id) ?? uid,
                inputChannels: AudioHAL.channelCount(of: id, input: true),
                outputChannels: AudioHAL.channelCount(of: id, input: false),
                sampleRate: AudioHAL.nominalSampleRate(of: id) ?? 0,
                canBeDefaultOutput: AudioHAL.canBeDefault(id, input: false),
                canBeDefaultInput: AudioHAL.canBeDefault(id, input: true))
        }
    }

    func defaultDevice(input: Bool) -> AudioObjectID? { AudioHAL.defaultDevice(input: input) }
    func name(of device: AudioObjectID) -> String? { AudioHAL.name(of: device) }
    func volume(of device: AudioObjectID) -> Double? { AudioHAL.volume(of: device) }
    func isMuted(_ device: AudioObjectID) -> Bool? { AudioHAL.isMuted(device) }
    func hasSettableVolume(_ device: AudioObjectID) -> Bool { AudioHAL.hasSettableVolume(device) }
    func hasSettableMute(_ device: AudioObjectID) -> Bool { AudioHAL.hasSettableMute(device) }
    func setVolume(_ device: AudioObjectID, _ value: Double) { AudioHAL.setVolume(device, value) }
    func setMute(_ device: AudioObjectID, _ muted: Bool) { AudioHAL.setMute(device, muted) }
    func setDefaultOutputDevice(_ device: AudioObjectID) -> OSStatus { AudioHAL.setDefaultOutputDevice(device) }

    func listenToSystem(_ handler: @escaping () -> Void) -> [AudioListenerToken] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        return [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                kAudioHardwarePropertyDefaultInputDevice].compactMap {
            AudioHAL.listen(system, AudioHAL.address($0), queue: AudioHAL.queue, handler)
        }
    }

    func listenToOutput(_ device: AudioObjectID, _ handler: @escaping () -> Void) -> [AudioListenerToken] {
        [AudioHAL.volumeAddress, AudioHAL.muteAddress].filter { AudioHAL.has(device, $0) }.compactMap {
            AudioHAL.listen(device, $0, queue: AudioHAL.queue, handler)
        }
    }
}

/// Cached view of the audio devices and of the default output's volume, kept current by Core Audio property
/// listeners. Nothing runs until a skin first asks (lazy activation); reads never touch the HAL, writes update the
/// cache at once (so `[!CommandMeasure … "ChangeVolume 10"][!Update]` shows the new value) and reach the HAL
/// asynchronously on `AudioHAL.queue`.
///
/// While a command waits for the HAL queue, HAL reads (a volume listener, the once-a-second re-read, a device
/// notification) leave the cached output state alone: they would briefly put back the value the command is about to
/// replace, and a second command in that moment (scroll-wheel volume: several `ChangeVolume 2` per second) would be
/// computed from the old value and lost. The re-read after the last queued command brings the cache back in line with
/// the device (e.g. a volume the device quantised).
final class AudioSystem: AudioOutputControlling {
    static let shared = AudioSystem()

    final class ObserverToken {
        fileprivate let id = UUID()
        fileprivate weak var system: AudioSystem?
        fileprivate init(system: AudioSystem) { self.system = system }
        deinit {
            let id = self.id
            if let system { AudioHAL.queue.async { system.observers[id] = nil } }
        }
    }

    let hal: AudioSystemHAL
    private let lock = NSLock()
    private var current = AudioSystemSnapshot()
    private var activated = false
    private var lastOutputRefresh: TimeInterval = 0
    private var outputRefreshPending = false
    /// Commands queued for the HAL and not carried out yet (under `lock`; see the type comment).
    private var pendingWrites = 0

    // HAL queue only.
    private var systemListeners: [AudioListenerToken] = []
    private var outputListeners: [AudioListenerToken] = []
    private var listenedOutput: AudioObjectID?
    private var observers: [UUID: () -> Void] = [:]
    private var refreshPending = false
    /// Device and volume before an emulated mute (devices without a mute control).
    private var emulatedMute: (device: AudioObjectID, volume: Double)?

    /// Seconds after which a read also re-reads the output state (in case a volume listener is not delivered).
    static let outputStaleness: TimeInterval = 1
    /// How long the first reader waits for the first read of the devices (once per app run). That read takes
    /// 55–65 ms on macOS 26.5 (Apple Silicon), so a shorter wait would block the main thread for nothing and still
    /// leave the skin's first update without a device name or volume.
    static let firstReadWait: TimeInterval = 0.2
    /// This instance's `firstReadWait` (tests give a slow fake HAL more time on a busy machine).
    let firstReadWait: TimeInterval

    init(hal: AudioSystemHAL = CoreAudioSystemHAL(), firstReadWait: TimeInterval = AudioSystem.firstReadWait) {
        self.hal = hal
        self.firstReadWait = firstReadWait
    }

    // MARK: Reading (any thread)

    func snapshot() -> AudioSystemSnapshot {
        activateIfNeeded()
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let result = current
        let stale = now - lastOutputRefresh > AudioSystem.outputStaleness && !outputRefreshPending
        if stale { outputRefreshPending = true }
        lock.unlock()
        if stale { scheduleOutputRefresh() }
        return result
    }

    /// Re-reads the output state on the HAL queue.
    func scheduleOutputRefresh() {
        AudioHAL.queue.async { self.refreshOutput() }
    }

    /// Starts listening and reads the devices. The first caller waits up to `wait` seconds (default:
    /// `firstReadWait`) for that read, so a skin's first update already has device names; a stalled HAL only delays
    /// it that long, once.
    func activateIfNeeded(wait: TimeInterval? = nil) {
        let wait = wait ?? firstReadWait
        lock.lock()
        let first = !activated
        activated = true
        lock.unlock()
        guard first else { return }
        if AudioHAL.isOnQueue {
            installSystemListeners()
            refresh()
            return
        }
        let done = DispatchSemaphore(value: 0)
        AudioHAL.queue.async {
            self.installSystemListeners()
            self.refresh()
            done.signal()
        }
        _ = done.wait(timeout: .now() + wait)
    }

    /// `handler` runs on `AudioHAL.queue` after every change of the devices or the default devices.
    func addObserver(_ handler: @escaping () -> Void) -> ObserverToken {
        let token = ObserverToken(system: self)
        let id = token.id
        let register = { self.observers[id] = handler }
        if AudioHAL.isOnQueue { register() } else { AudioHAL.queue.async(execute: register) }
        activateIfNeeded(wait: 0)
        return token
    }

    // MARK: Control (any thread)

    func setOutputVolume(_ volume: Double) {
        setOutputVolume { _ in volume }
    }

    /// Skins on different threads may change the volume at once (docs/skin-threading.md §4.7): the new volume is
    /// worked out from the cached one under the same lock that stores it, so no step is lost.
    func changeOutputVolume(byPercent delta: Double) {
        setOutputVolume { AudioSystem.changedVolume($0, byPercent: delta) }
    }

    /// `volume` (0…1; nil without a volume control: full level) changed by `delta` percentage points, within 0…1.
    static func changedVolume(_ volume: Double?, byPercent delta: Double) -> Double {
        let percent = (volume ?? 1) * 100 + delta
        return percent.isNaN ? 0 : min(max(percent, 0), 100) / 100
    }

    /// `volume` gets the cached volume (nil without a volume control) and returns the new one, under the lock. The
    /// write is queued under the lock too, so the device gets the volumes in the order they were worked out.
    private func setOutputVolume(_ volume: (Double?) -> Double) {
        lock.lock()
        defer { lock.unlock() }
        let wanted = volume(current.output.volume)
        let v = wanted.isFinite ? min(max(wanted, 0), 1) : 0
        current.output.volume = current.output.volume == nil && !current.output.canSetVolume ? nil : v
        current.output.muted = false
        pendingWrites += 1
        write {
            guard let device = self.hal.defaultDevice(input: false) else { return }
            if let saved = self.emulatedMute {
                // Unmuting an emulated mute: the new volume replaces the saved one.
                self.emulatedMute = nil
                if saved.device != device { self.hal.setVolume(saved.device, saved.volume) }
            }
            if self.hal.hasSettableMute(device), self.hal.isMuted(device) == true { self.hal.setMute(device, false) }
            if self.hal.hasSettableVolume(device) { self.hal.setVolume(device, v) }
        }
    }

    func setOutputMuted(_ muted: Bool) {
        setOutputMuted { _ in muted }
    }

    /// One step, like `changeOutputVolume(byPercent:)`.
    func toggleOutputMuted() {
        setOutputMuted { !$0 }
    }

    /// `decide` gets the cached mute state and returns the new one, under the lock, where the write is queued too.
    private func setOutputMuted(_ decide: (Bool) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        let muted = decide(current.output.muted)
        current.output.muted = muted
        pendingWrites += 1
        write {
            guard let device = self.hal.defaultDevice(input: false) else { return }
            if self.hal.hasSettableMute(device) {
                self.hal.setMute(device, muted)
            } else if self.hal.hasSettableVolume(device) {
                // No mute control: mute by setting the volume to 0 and restore it on unmute.
                if muted {
                    if self.emulatedMute == nil {
                        self.emulatedMute = (device, self.hal.volume(of: device) ?? 1)
                        self.hal.setVolume(device, 0)
                    }
                } else if let saved = self.emulatedMute {
                    self.hal.setVolume(saved.device, saved.volume)
                    self.emulatedMute = nil
                }
            }
        }
    }

    func setDefaultOutput(_ device: AudioObjectID) {
        lock.lock()
        if let info = current.device(device) {
            // Until the HAL answers (a moment later) the new device shows the old volume state.
            current.defaultOutput = device
            current.output.deviceID = device
            current.output.name = info.name
        }
        pendingWrites += 1
        lock.unlock()
        write(thenRefreshDevices: true) {
            let status = self.hal.setDefaultOutputDevice(device)
            if status != noErr { Log.write("Could not switch the audio output (\(status))", level: .warning,
                                           source: "Audio") }
        }
    }

    /// Runs a command's HAL work on the HAL queue, then re-reads the state (the caller counted it in
    /// `pendingWrites`). Only queues: callers may hold `lock`.
    private func write(thenRefreshDevices devices: Bool = false, _ body: @escaping () -> Void) {
        AudioHAL.queue.async {
            body()
            self.lock.lock()
            self.pendingWrites -= 1
            self.lock.unlock()
            if devices { self.refresh() } else { self.refreshOutput() }
        }
    }

    // MARK: HAL side (AudioHAL.queue)

    private func installSystemListeners() {
        guard systemListeners.isEmpty else { return }
        systemListeners = hal.listenToSystem { [weak self] in self?.scheduleRefresh() }
    }

    /// Notifications come in bursts (a device appearing changes the list and the defaults): read once.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        AudioHAL.queue.asyncAfter(deadline: .now() + 0.05) {
            self.refreshPending = false
            self.refresh()
        }
    }

    /// Reads the devices and the output state, then tells the observers.
    private func refresh() {
        let devices = hal.devices()
        let defaultOutput = hal.defaultDevice(input: false)
        let defaultInput = hal.defaultDevice(input: true)
        if let saved = emulatedMute, saved.device != defaultOutput {
            // The output changed while muted by volume: give the old device its volume back.
            hal.setVolume(saved.device, saved.volume)
            emulatedMute = nil
        }
        let output = readOutput(defaultOutput, names: devices)
        listenToOutput(defaultOutput)
        lock.lock()
        current.loaded = true
        current.devices = devices
        current.defaultInput = defaultInput
        if pendingWrites == 0 {
            current.defaultOutput = defaultOutput
            current.output = output
            lastOutputRefresh = ProcessInfo.processInfo.systemUptime
        }
        lock.unlock()
        for handler in observers.values { handler() }
    }

    private func refreshOutput() {
        let device = hal.defaultDevice(input: false)
        lock.lock()
        let devices = current.devices
        lock.unlock()
        let output = readOutput(device, names: devices)
        lock.lock()
        if pendingWrites == 0 {
            current.output = output
            current.defaultOutput = device
        }
        lastOutputRefresh = ProcessInfo.processInfo.systemUptime
        outputRefreshPending = false
        lock.unlock()
    }

    private func readOutput(_ device: AudioObjectID?, names: [AudioDeviceInfo]) -> AudioOutputState {
        guard let device else { return AudioOutputState() }
        var state = AudioOutputState(deviceID: device)
        state.name = names.first { $0.id == device }?.name ?? hal.name(of: device) ?? ""
        state.volume = hal.volume(of: device)
        state.canSetVolume = hal.hasSettableVolume(device)
        state.canMute = hal.hasSettableMute(device)
        state.muted = (hal.isMuted(device) ?? false) || emulatedMute?.device == device
        if let saved = emulatedMute, saved.device == device { state.volume = saved.volume }
        return state
    }

    private func listenToOutput(_ device: AudioObjectID?) {
        guard device != listenedOutput else { return }
        outputListeners.forEach { $0.remove() }
        outputListeners = []
        listenedOutput = device
        guard let device else { return }
        outputListeners = hal.listenToOutput(device) { [weak self] in self?.refreshOutput() }
    }
}
