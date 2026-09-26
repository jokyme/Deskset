import AVFoundation
import AppKit
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

// Capture backends. All start/stop on AudioHAL.queue; their IOProcs run on Core Audio's real-time thread and only
// copy samples into the ring (AudioRingBuffer.write never allocates or waits).
//
// Permissions (asked lazily, the first time a skin needs the stream; refusing never blocks or crashes — the
// measures then read 0):
// - System audio via a Core Audio process tap (macOS 14.2+): "System Audio Recording" (Info.plist
//   NSAudioCaptureUsageDescription). macOS shows its audio-recording indicator in the menu bar while it runs.
// - System audio via ScreenCaptureKit (macOS 13 – 14.1): "Screen Recording".
// - Microphone / input devices: "Microphone" (NSMicrophoneUsageDescription).

enum AudioPermissions {
    /// A bundled app that asks for a protected resource without the Info.plist usage description is killed by
    /// the system; such a build refuses instead. (Unbundled `swift run` builds borrow the terminal's permission.)
    static func hasUsageDescription(_ key: String) -> Bool {
        !Paths.isAppBundle || Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    /// Compatibility notes for skins whose audio stream a refused permission keeps silent.
    static let microphoneNote = "AudioLevel with Port=Input needs microphone access for Deskset: allow it in System "
        + "Settings → Privacy & Security → Microphone. Until then the levels read 0."
    static let screenRecordingNote = "On macOS 13 – 14.1, AudioLevel needs the Screen Recording permission to hear "
        + "system audio: allow Deskset in System Settings → Privacy & Security → Screen Recording, then quit and open "
        + "Deskset again. Until then the levels read 0."

    private static let lock = NSLock()
    private static var logged: Set<String> = []

    /// Logs a capture problem once per app run (the skins show 0 meanwhile).
    static func logOnce(_ message: String) {
        lock.lock()
        let first = logged.insert(message).inserted
        lock.unlock()
        if first { Log.write(message, level: .warning, source: "Audio") }
    }
}

extension AudioSourceStatus {
    /// `permissionNote`: the refused permission in words for the user (see `AudioSourceStatus.permissionNote`).
    static func failed(_ message: String, device: AudioObjectID? = nil, permissionNote: String? = nil) -> AudioSourceStatus {
        AudioPermissions.logOnce("Audio capture: \(message)")
        var s = AudioSourceStatus(message: message, permissionNote: permissionNote)
        if let device {
            s.deviceName = AudioHAL.name(of: device) ?? ""
            s.deviceUID = AudioHAL.uid(of: device) ?? ""
        }
        return s
    }
}

private func isFloat32(_ f: AudioStreamBasicDescription) -> Bool {
    f.mFormatID == kAudioFormatLinearPCM && f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
}

// MARK: - Process tap (macOS 14.2+)

/// System output through a Core Audio process tap: a global stereo tap of every process (default), a tap of one
/// output device's stream (`ID=` names a device), or a tap of one process (AppVolume peaks), read through a private
/// aggregate device whose clock is the output device (or only the tap, see `aggregateDescription`).
@available(macOS 14.2, *)
final class ProcessTapBackend: AudioCaptureBackend {
    let key: AudioSourceKey
    private(set) var deviceID: AudioObjectID?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var listeners: [AudioListenerToken] = []

    init(key: AudioSourceKey) {
        self.key = key
    }

    /// A refused System Audio Recording permission gives a tap that runs and carries zeros.
    var deliversSilenceWhenRefused: Bool { key.kind == .output }

    func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
        guard AudioPermissions.hasUsageDescription("NSAudioCaptureUsageDescription") else {
            return .failed("this build lacks NSAudioCaptureUsageDescription; system audio cannot be captured")
        }
        guard let resolved = AudioCaptureEngine.resolveDevice(key) else { return .failed("no audio output device") }
        let device = resolved.device
        deviceID = device
        guard let outputUID = AudioHAL.uid(of: device) else { return .failed("the output device has no UID") }

        let description: CATapDescription
        switch key.kind {
        case .process(let pid):
            guard let object = AudioProcesses.object(for: pid) else {
                return .failed("process \(pid) plays no audio", device: device)
            }
            description = CATapDescription(stereoMixdownOfProcesses: [object])
        case .output, .input:
            if key.deviceID != nil && !resolved.fallback {
                description = CATapDescription(excludingProcesses: [], deviceUID: outputUID, stream: 0)
            } else {
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            }
        }
        description.name = "Deskset AudioLevel"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            return .failed("cannot create the system audio tap (\(status))", device: device)
        }
        tapID = tap
        guard let format = AudioHAL.get(tap, AudioHAL.address(kAudioTapPropertyFormat),
                                        as: AudioStreamBasicDescription.self), isFloat32(format),
              format.mChannelsPerFrame > 0 else {
            stop()
            return .failed("the system audio tap has an unexpected format", device: device)
        }

        let aggregateDescription = ProcessTapBackend.aggregateDescription(
            outputUID: outputUID, tapUUID: description.uuid.uuidString,
            includeOutputDevice: AudioHAL.channelCount(of: device, input: true) == 0)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            stop()
            return .failed("cannot create the capture device (\(status))", device: device)
        }
        aggregateID = aggregate

        // The tap's stream comes after the output device's own input streams (if any): keep only its buffers.
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let tapBuffers = nonInterleaved ? Int(format.mChannelsPerFrame) : 1
        let block: AudioDeviceIOBlock = { _, input, _, output, _ in
            ring.write(input, lastBuffers: tapBuffers)
            ring.zeroOutput(output)
        }
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil, block)
        guard status == noErr, let proc else {
            stop()
            return .failed("cannot read the capture device (\(status))", device: device)
        }
        procID = proc
        status = AudioDeviceStart(aggregate, proc)
        guard status == noErr else {
            stop()
            return .failed("cannot start the system audio capture (\(status))", device: device)
        }
        // A new sample rate on the output device changes the stream: start over.
        if let token = AudioHAL.listen(device, AudioHAL.address(kAudioDevicePropertyNominalSampleRate),
                                       queue: AudioHAL.queue, { events.restart() }) {
            listeners.append(token)
        }
        let rate = AudioHAL.nominalSampleRate(of: aggregate) ?? (format.mSampleRate > 0 ? format.mSampleRate : 48000)
        let channels = Int(format.mChannelsPerFrame)
        var result = AudioSourceStatus(
            running: true, deviceName: AudioHAL.name(of: device) ?? outputUID, deviceUID: outputUID,
            format: AudioHAL.describe(sampleRate: rate, bitsPerChannel: 32, isFloat: true, channels: channels),
            sampleRate: rate, channels: channels)
        if resolved.fallback, let id = key.deviceID {
            result.message = "no output device with ID \(id); using the default output"
        }
        return result
    }

    /// The private aggregate device that reads the tap. Normally the output device is its main sub-device (its
    /// clock drives the aggregate). A device that also has inputs (USB audio interfaces, headsets, virtual devices
    /// such as BlackHole) is left out: as a sub-device it brings its input streams into the aggregate, and running
    /// the aggregate would record them too — the microphone permission and indicator, and Bluetooth headsets
    /// dropping to their low-quality call profile. The aggregate then holds only the tap, which is also what macOS
    /// builds when the output is a Multi-Output Device (an aggregate cannot contain one).
    static func aggregateDescription(outputUID: String, tapUUID: String, includeOutputDevice: Bool) -> [String: Any] {
        var d: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Deskset Audio Tap",
            kAudioAggregateDeviceUIDKey: AudioHAL.ownDevicePrefix + "tap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID]],
        ]
        if includeOutputDevice {
            d[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            d[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        return d
    }

    func stop() {
        listeners.forEach { $0.remove() }
        listeners = []
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }
}

// MARK: - Input device

/// `Port=Input`: an IOProc directly on the input device (default input, or the device named by `ID`).
final class InputDeviceBackend: AudioCaptureBackend {
    let key: AudioSourceKey
    private(set) var deviceID: AudioObjectID?
    private var procID: AudioDeviceIOProcID?
    private var listeners: [AudioListenerToken] = []
    /// HAL queue only: the system prompt is shown once per app run.
    private static var requestedAccess = false

    init(key: AudioSourceKey) {
        self.key = key
    }

    func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
        guard let resolved = AudioCaptureEngine.resolveDevice(key) else { return .failed("no audio input device") }
        let device = resolved.device
        deviceID = device
        guard AudioPermissions.hasUsageDescription("NSMicrophoneUsageDescription") else {
            return .failed("this build lacks NSMicrophoneUsageDescription; input devices cannot be read", device: device)
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            if !InputDeviceBackend.requestedAccess {
                InputDeviceBackend.requestedAccess = true
                AVCaptureDevice.requestAccess(for: .audio) { granted in if granted { events.restart() } }
            }
            let uid = AudioHAL.uid(of: device) ?? ""
            return AudioSourceStatus(deviceName: AudioHAL.name(of: device) ?? uid, deviceUID: uid,
                                     message: "waiting for the microphone permission")
        default:
            return .failed("microphone access is off (System Settings → Privacy & Security → Microphone)",
                           device: device, permissionNote: AudioPermissions.microphoneNote)
        }
        guard let format = AudioHAL.inputStreamFormat(of: device), isFloat32(format) else {
            return .failed("the input device has an unexpected format", device: device)
        }
        let channels = AudioHAL.channelCount(of: device, input: true)
        guard channels > 0 else { return .failed("the input device has no channels", device: device) }

        let block: AudioDeviceIOBlock = { _, input, _, output, _ in
            ring.write(input)
            ring.zeroOutput(output)
        }
        var proc: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil, block)
        guard status == noErr, let proc else {
            return .failed("cannot read the input device (\(status))", device: device)
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            stop()
            return .failed("cannot start the input device (\(status))", device: device)
        }
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyStreamConfiguration] {
            let a = AudioHAL.address(selector, selector == kAudioDevicePropertyStreamConfiguration
                                     ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeGlobal)
            if let token = AudioHAL.listen(device, a, queue: AudioHAL.queue, { events.restart() }) {
                listeners.append(token)
            }
        }
        let rate = AudioHAL.nominalSampleRate(of: device) ?? format.mSampleRate
        let uid = AudioHAL.uid(of: device) ?? ""
        var result = AudioSourceStatus(
            running: true, deviceName: AudioHAL.name(of: device) ?? uid, deviceUID: uid,
            format: AudioHAL.describe(sampleRate: rate, bitsPerChannel: 32, isFloat: true, channels: channels),
            sampleRate: rate, channels: channels)
        if resolved.fallback, let id = key.deviceID {
            result.message = "no input device with ID \(id); using the default input"
        }
        return result
    }

    func stop() {
        listeners.forEach { $0.remove() }
        listeners = []
        if let procID, let deviceID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
    }

    deinit { stop() }
}

// MARK: - ScreenCaptureKit (macOS 13 – 14.1)

/// System audio before process taps existed: a ScreenCaptureKit stream of the main display with audio (video
/// frames at 1 fps, 2×2 pixels, ignored). Needs the Screen Recording permission; it always captures the whole
/// system mix (`ID` cannot pick a device) at 48 kHz stereo.
final class ScreenCaptureAudioBackend: NSObject, AudioCaptureBackend, SCStreamOutput, SCStreamDelegate {
    let key: AudioSourceKey
    private(set) var deviceID: AudioObjectID?
    private var stream: SCStream?
    private var ring: AudioRingBuffer?
    private var events: AudioBackendEvents?
    private var stopped = false
    private let sampleQueue = DispatchQueue(label: "net.deskset.audio.screencapture")
    private static var requestedAccess = false
    static let sampleRate = 48000.0

    init(key: AudioSourceKey) {
        self.key = key
    }

    func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
        let device = AudioHAL.defaultDevice(input: false)
        deviceID = device
        guard CGPreflightScreenCaptureAccess() else {
            if !ScreenCaptureAudioBackend.requestedAccess {
                ScreenCaptureAudioBackend.requestedAccess = true
                DispatchQueue.main.async { _ = CGRequestScreenCaptureAccess() }
            }
            return .failed("on macOS 13 – 14.1 system audio needs the Screen Recording permission "
                           + "(System Settings → Privacy & Security → Screen Recording), then a restart of Deskset",
                           device: device, permissionNote: AudioPermissions.screenRecordingNote)
        }
        self.ring = ring
        self.events = events
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, error in
            AudioHAL.queue.async { self?.didLoad(content, error: error) }
        }
        var s = AudioSourceStatus(message: "starting")
        if let device {
            s.deviceName = AudioHAL.name(of: device) ?? ""
            s.deviceUID = AudioHAL.uid(of: device) ?? ""
        }
        return s
    }

    private func didLoad(_ content: SCShareableContent?, error: Error?) {
        guard !stopped, let events else { return }
        guard let display = content?.displays.first else {
            events.status(.failed("ScreenCaptureKit found no display (\(error?.localizedDescription ?? "no content"))"))
            return
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = Int(ScreenCaptureAudioBackend.sampleRate)
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            events.status(.failed("ScreenCaptureKit refused the audio stream (\(error.localizedDescription))"))
            return
        }
        self.stream = stream
        let device = deviceID
        stream.startCapture { error in
            AudioHAL.queue.async { [weak self] in
                guard let self, !self.stopped else {
                    // Stopped (or released) while the stream was still starting: `stop()` could not stop a stream
                    // that was not running yet, so stop it now — otherwise it would capture with nobody reading it.
                    if error == nil { stream.stopCapture(completionHandler: nil) }
                    return
                }
                if let error {
                    events.status(.failed("cannot start ScreenCaptureKit (\(error.localizedDescription))"))
                    return
                }
                let name = device.flatMap(AudioHAL.name(of:)) ?? ""
                events.status(AudioSourceStatus(
                    running: true, deviceName: name, deviceUID: device.flatMap(AudioHAL.uid(of:)) ?? "",
                    format: AudioHAL.describe(sampleRate: ScreenCaptureAudioBackend.sampleRate, bitsPerChannel: 32,
                                              isFloat: true, channels: 2),
                    sampleRate: ScreenCaptureAudioBackend.sampleRate, channels: 2))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let ring, sampleBuffer.isValid else { return }
        if let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription, !isFloat32(asbd) { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            ring.write(UnsafePointer(list.unsafePointer))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        events?.restart()
    }

    func stop() {
        stopped = true
        stream?.stopCapture(completionHandler: nil)
        stream = nil
    }
}

// MARK: - Processes (macOS 14.2+)

/// A process that is a Core Audio client (AppVolume).
struct AudioProcessInfo: Equatable {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isRunningOutput: Bool
}

enum AudioProcesses {
    /// Core Audio's process objects (HAL queue). Empty before macOS 14.2.
    static func list() -> [AudioProcessInfo] {
        guard #available(macOS 14.2, *) else { return [] }
        let objects = AudioHAL.array(AudioObjectID(kAudioObjectSystemObject),
                                     AudioHAL.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
        return objects.compactMap { object in
            guard let pid = AudioHAL.get(object, AudioHAL.address(kAudioProcessPropertyPID), as: pid_t.self) else {
                return nil
            }
            let bundle = AudioHAL.string(object, AudioHAL.address(kAudioProcessPropertyBundleID)) ?? ""
            let running = (AudioHAL.get(object, AudioHAL.address(kAudioProcessPropertyIsRunningOutput),
                                        as: UInt32.self) ?? 0) != 0
            return AudioProcessInfo(objectID: object, pid: pid, bundleID: bundle, isRunningOutput: running)
        }
    }

    static func object(for pid: pid_t) -> AudioObjectID? {
        list().first { $0.pid == pid }?.objectID
    }
}

// MARK: - Demo signal

/// `DESKSET_AUDIO_DEMO=1`: a generated, deterministic "music" signal instead of real capture — pink noise, a kick
/// every half second, a hi-hat and a four-note melody (right channel a little quieter). No permission is needed, so
/// visualizer skins can be checked with `--render`, screenshotted or demoed without playing anything.
final class SyntheticAudioBackend: AudioCaptureBackend {
    let deviceID: AudioObjectID? = nil
    static let sampleRate = 48000.0
    private let queue = DispatchQueue(label: "net.deskset.audio.demo", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var started: TimeInterval = 0
    private var produced = 0
    private var pink = [Double](repeating: 0, count: 7)
    private var random: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var buffer: [Float] = []

    func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus {
        started = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self, weak ring] in
            guard let self, let ring else { return }
            self.generate(into: ring)
        }
        timer.resume()
        self.timer = timer
        return AudioSourceStatus(running: true, deviceName: "Deskset Demo Signal", deviceUID: "DesksetDemoSignal",
                                 format: AudioHAL.describe(sampleRate: SyntheticAudioBackend.sampleRate,
                                                           bitsPerChannel: 32, isFloat: true, channels: 2),
                                 sampleRate: SyntheticAudioBackend.sampleRate, channels: 2)
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Frames up to "now", so the stream runs in real time whatever the timer's jitter.
    private func generate(into ring: AudioRingBuffer) {
        let due = Int((ProcessInfo.processInfo.systemUptime - started) * SyntheticAudioBackend.sampleRate)
        let frames = min(max(due - produced, 0), 9600)
        guard frames > 0 else { return }
        if buffer.count < frames * 2 { buffer = [Float](repeating: 0, count: frames * 2) }
        let sr = SyntheticAudioBackend.sampleRate
        let notes = [220.0, 277.18, 329.63, 440.0]
        for i in 0..<frames {
            let t = Double(produced + i) / sr
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(random >> 11) / Double(1 << 53) * 2 - 1
            // Pink noise (Paul Kellet's filter).
            pink[0] = 0.99886 * pink[0] + white * 0.0555179
            pink[1] = 0.99332 * pink[1] + white * 0.0750759
            pink[2] = 0.96900 * pink[2] + white * 0.1538520
            pink[3] = 0.86650 * pink[3] + white * 0.3104856
            pink[4] = 0.55000 * pink[4] + white * 0.5329522
            pink[5] = -0.7616 * pink[5] - white * 0.0168980
            let pinkValue = (pink[0] + pink[1] + pink[2] + pink[3] + pink[4] + pink[5] + pink[6] + white * 0.5362) * 0.11
            pink[6] = white * 0.115926
            let beat = t.truncatingRemainder(dividingBy: 0.5)
            let kick = sin(2 * .pi * 55 * t) * exp(-beat * 9) * 0.55
            let half = t.truncatingRemainder(dividingBy: 0.25)
            let hat = white * exp(-half * 45) * 0.12
            let note = notes[Int(t / 0.5) % notes.count]
            let melody = sin(2 * .pi * note * t) * 0.14 * (0.7 + 0.3 * sin(2 * .pi * 0.25 * t))
            let mix = pinkValue * 0.35 + kick + hat
            buffer[2 * i] = Float(mix + melody)
            buffer[2 * i + 1] = Float(mix + melody * 0.6)
        }
        buffer.withUnsafeBufferPointer { ring.write(interleaved: $0.baseAddress!, frames: frames, channels: 2) }
        produced += frames
    }
}
