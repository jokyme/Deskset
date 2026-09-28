import Accelerate
import CoreAudio
import Foundation
import os

// One shared capture engine for every AudioLevel measure of every skin.
//
// - A "source" is one audio stream: the system output (all apps, or one output device), an input device, or one
//   process (AppVolume peaks). Measures (AudioLevel parents, AppVolume peak children) subscribe an analyzer to a
//   source when they update in a skin window, never when their options are read (`AudioPlugins.mayCapture(for:)`);
//   the source starts capturing when its first analyzer arrives and stops a few seconds after its last one leaves
//   (a skin refresh recreates its measures, and the grace period avoids tearing the capture down and building it
//   again). System audio on macOS 14.2+ is captured only while another process plays sound (`outputActivity`);
//   between times its source waits in `standby`, with no tap and so no recording indicator.
// - The real-time audio thread only copies samples into a preallocated ring buffer (no allocation, no blocking
//   lock: it uses a try-lock and drops the slice in the rare case the reader holds the lock).
// - An analysis timer (≈ 60 Hz, background queue) drains the ring and feeds the analyzers; measures read the
//   analyzers' latest published values from the main thread.
// - HAL work (creating taps, aggregate devices, IOProcs; device lookups) runs on `AudioHAL.queue`.

/// Which stream a source captures.
enum AudioSourceKind: Hashable {
    /// System audio output (`Port=Output`).
    case output
    /// An input device (`Port=Input`).
    case input
    /// The audio output of one process (AppVolume).
    case process(pid_t)
}

struct AudioSourceKey: Hashable {
    var kind: AudioSourceKind
    /// `ID=` as written (device UID or name); nil = the default device, following changes.
    var deviceID: String?
}

/// What skins can learn about a source (`Type=DeviceStatus`, `MacPermission`, `DeviceName`, `DeviceID`, `Format`).
struct AudioSourceStatus: Equatable {
    var running = false
    var deviceName = ""
    var deviceUID = ""
    var format = ""
    var sampleRate = 0.0
    var channels = 0
    /// Why the source does not run, or a note about it (logged once by the measures).
    var message: String?
    /// A missing macOS permission, in words for the user (shown as a compatibility note of the skins using the
    /// source): nil when nothing is known to be missing.
    var permissionNote: String?
    /// System audio waits for another app to play sound (`AudioCaptureEngine.outputActivity`): nothing is captured, so
    /// there is no recording indicator, but the device is there.
    var standby = false
    /// The silence watchdog suspects a refused permission (`AudioCaptureEngine.silenceNote`).
    var refusalSuspected = false
    /// A macOS permission known to keep the source from running: refused (`permissionNote` says so in words), or not
    /// decided yet (`permissionUndecided`: macOS's prompt may be on screen). nil when nothing is known to be missing.
    /// A suspected refusal of System Audio Recording is `refusalSuspected` instead.
    var missingPermission: AudioPermission?
    var permissionUndecided = false

    /// `Type=DeviceStatus`, Rainmeter's 0 or 1: 1 while the capture runs or waits for sound (also while the silence
    /// watchdog suspects a refused permission: the device is there), 0 when nothing can be captured (no device, a
    /// refused microphone or Screen Recording, command-line mode).
    var deviceStatus: Int { running || standby ? 1 : 0 }

    /// `Type=MacPermission` (Deskset extension): 1 while a permission keeps the source from being heard (for System
    /// Audio Recording: suspected by the silence watchdog), 2 while macOS has not had an answer yet (its prompt may be
    /// on screen), else 0. The string names the permission as System Settings does ("" for 0).
    var macPermission: (number: Int, name: String) {
        if refusalSuspected { return (1, AudioPermission.systemAudioRecording.rawValue) }
        guard let missing = missingPermission else { return (0, "") }
        return (permissionUndecided ? 2 : 1, missing.rawValue)
    }
}

/// A macOS permission audio capture needs, by its name in System Settings › Privacy & Security.
enum AudioPermission: String {
    /// macOS 14.2+, `Port=Output`: "Screen & System Audio Recording" › "System Audio Recording Only".
    case systemAudioRecording = "System Audio Recording"
    /// macOS 13 – 14.1, `Port=Output` (ScreenCaptureKit).
    case screenRecording = "Screen Recording"
    /// `Port=Input`.
    case microphone = "Microphone"
}

/// Whether a process other than Deskset plays sound, and when that changes (HAL queue only). A system-audio capture
/// runs only while one does (`AudioCaptureEngine.outputActivity`).
protocol AudioOutputActivity: AnyObject {
    /// Whether another process runs audio output now.
    func othersPlay() -> Bool
    /// Calls `handler` on the HAL queue whenever `othersPlay()` may have changed, until `stopObserving()`.
    func observe(_ handler: @escaping () -> Void)
    func stopObserving()
}

/// Callbacks from a backend to the engine (any thread).
struct AudioBackendEvents {
    /// Stop and start again (device, format or permission changed).
    let restart: () -> Void
    /// Status of a backend that finishes starting asynchronously.
    let status: (AudioSourceStatus) -> Void
}

protocol AudioCaptureBackend: AnyObject {
    /// Device captured (nil for backends that follow the system as a whole); a change triggers a restart.
    var deviceID: AudioObjectID? { get }
    /// Starts writing Float32 frames into `ring` (HAL queue). The returned status says whether it runs.
    func start(ring: AudioRingBuffer, events: AudioBackendEvents) -> AudioSourceStatus
    /// Stops and releases everything (HAL queue). Called once.
    func stop()
    /// A refused permission cannot be detected up front: the stream runs but carries only digital silence (Core
    /// Audio process taps without System Audio Recording). The engine then watches for that (see
    /// `AudioCaptureEngine.silenceNote`).
    var deliversSilenceWhenRefused: Bool { get }
}

extension AudioCaptureBackend {
    var deliversSilenceWhenRefused: Bool { false }
}

// MARK: - Ring buffer

/// Single-producer / single-consumer ring of interleaved Float32 frames, up to 8 channels (stride 8).
/// The producer is the real-time audio thread: `write` never allocates and never waits.
final class AudioRingBuffer {
    static let stride = AudioAnalyzer.maxChannels
    /// Frames (power of two): ≈ 0.7 s at 48 kHz, far more than one analysis tick.
    let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    /// [0] frames written, [1] frames read, [2] channels of the latest write, [3] slices dropped.
    private let state: UnsafeMutablePointer<Int>
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Byte offset of `mBuffers` in an AudioBufferList, computed here so the real-time path uses no key path.
    private let buffersOffset: Int

    init(capacity: Int = 1 << 15) {
        buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \AudioBufferList.mBuffers) ?? 8
        var c = 1
        while c < max(capacity, 256) { c <<= 1 }
        self.capacity = c
        samples = .allocate(capacity: c * AudioRingBuffer.stride)
        samples.initialize(repeating: 0, count: c * AudioRingBuffer.stride)
        state = .allocate(capacity: 4)
        state.initialize(repeating: 0, count: 4)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        samples.deallocate()
        state.deallocate()
        lock.deallocate()
    }

    /// Slices dropped because the reader held the lock (diagnostics).
    var droppedSlices: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return state[3]
    }

    /// Real-time safe. Accepts interleaved (one buffer, n channels) and non-interleaved (n buffers) Float32 lists.
    /// `lastBuffers` keeps only the last n buffers (a tap's stream follows the sub-device's own input streams in
    /// an aggregate device).
    func write(_ list: UnsafePointer<AudioBufferList>, lastBuffers: Int = Int.max) {
        // Index loops over the raw buffer array only: no generic iterators on the real-time thread (an unspecialised
        // generic could instantiate type metadata, i.e. allocate, on first use).
        let count = Int(list.pointee.mNumberBuffers)
        guard count > 0 else { return }
        let buffers = (UnsafeRawPointer(list) + buffersOffset).assumingMemoryBound(to: AudioBuffer.self)
        let skip = lastBuffers < count ? count - lastBuffers : 0
        var frames = Int.max
        var channels = 0
        var i = skip
        while i < count {
            let n = Int(buffers[i].mNumberChannels)
            if n > 0, buffers[i].mData != nil {
                frames = min(frames, Int(buffers[i].mDataByteSize) / (4 * n))
                channels += n
            }
            i += 1
        }
        guard channels > 0, frames != Int.max, frames > 0 else { return }
        guard os_unfair_lock_trylock(lock) else {
            state[3] &+= 1
            return
        }
        let written = state[0]
        let mask = capacity - 1
        let stride = AudioRingBuffer.stride
        var base = 0
        i = skip
        while i < count {
            let n = Int(buffers[i].mNumberChannels)
            if n > 0, let raw = buffers[i].mData {
                let data = raw.assumingMemoryBound(to: Float.self)
                var c = 0
                while c < n && base + c < stride {
                    var slot = written
                    var f = 0
                    while f < frames {
                        samples[(slot & mask) * stride + base + c] = data[f * n + c]
                        slot &+= 1
                        f += 1
                    }
                    c += 1
                }
                base += n
            }
            i += 1
        }
        finishWrite(frames: frames, channels: min(channels, stride))
        os_unfair_lock_unlock(lock)
    }

    /// Interleaved frames (ScreenCaptureKit, tests).
    func write(interleaved data: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        guard os_unfair_lock_trylock(lock) else {
            state[3] &+= 1
            return
        }
        let written = state[0]
        let mask = capacity - 1
        let used = min(channels, AudioRingBuffer.stride)
        for f in 0..<frames {
            let slot = ((written &+ f) & mask) * AudioRingBuffer.stride
            for c in 0..<used { samples[slot + c] = data[f * channels + c] }
        }
        finishWrite(frames: frames, channels: used)
        os_unfair_lock_unlock(lock)
    }

    /// Under the lock: advances the write position; a reader that fell more than `capacity` behind loses the
    /// oldest frames.
    private func finishWrite(frames: Int, channels: Int) {
        state[0] &+= frames
        state[2] = channels
        if state[0] &- state[1] > capacity { state[1] = state[0] &- capacity }
    }

    /// Copies the frames written since the last read (at most `maxFrames`, the newest ones) into `destination`
    /// (stride 8). Returns the frame count and the channel count.
    func read(into destination: UnsafeMutablePointer<Float>, maxFrames: Int) -> (frames: Int, channels: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        var available = state[0] &- state[1]
        if available > maxFrames {
            state[1] = state[0] &- maxFrames
            available = maxFrames
        }
        guard available > 0 else { return (0, state[2]) }
        let mask = capacity - 1
        var slot = state[1]
        for f in 0..<available {
            (destination + f * AudioRingBuffer.stride)
                .update(from: samples + (slot & mask) * AudioRingBuffer.stride, count: AudioRingBuffer.stride)
            slot &+= 1
        }
        state[1] = state[0]
        return (available, state[2])
    }

    func clear() {
        os_unfair_lock_lock(lock)
        state[1] = state[0]
        os_unfair_lock_unlock(lock)
    }

    /// Real-time safe: silences an IOProc's output buffers (Deskset never plays through its capture devices).
    func zeroOutput(_ list: UnsafeMutablePointer<AudioBufferList>) {
        let count = Int(list.pointee.mNumberBuffers)
        let buffers = (UnsafeMutableRawPointer(list) + buffersOffset).assumingMemoryBound(to: AudioBuffer.self)
        var i = 0
        while i < count {
            if let data = buffers[i].mData { memset(data, 0, Int(buffers[i].mDataByteSize)) }
            i += 1
        }
    }
}

// MARK: - What measures ask of it

/// What AudioLevel measures ask of the capture engine: the engine itself, or levels given as data (`--render --data`,
/// `ScriptedAudioLevels`).
protocol AudioLevelEngine: AnyObject {
    /// Feeds `analyzer` from the source of `key` from now on (any thread).
    func subscribe(_ analyzer: AudioAnalyzer, to key: AudioSourceKey)
    func unsubscribe(_ analyzer: AudioAnalyzer)
    /// Latest status of a source.
    func status(for key: AudioSourceKey) -> AudioSourceStatus
    /// True when subscribing captures nothing at all (levels given as data): a skin outside a skin window may
    /// subscribe without asking `AudioPlugins.mayCapture(for:)`.
    var capturesNothing: Bool { get }
}

// MARK: - Engine

final class AudioCaptureEngine: AudioLevelEngine {
    static let shared: AudioCaptureEngine = {
        let engine = AudioCaptureEngine()
        if captureAllowed {
            engine.outputActivity = CoreAudioOutputActivity.makeIfSupported()
            engine.watchPermissionChanges = AudioPermissions.watchSystemSettings
        }
        return engine
    }()

    /// Command-line modes (`--render`, `--self-test`, …) never capture: rendering a skin must not ask for the
    /// microphone or system audio. `DESKSET_AUDIO_CAPTURE=1` forces capture there for skin windows (a render has
    /// none, so it never captures: `AudioPlugins.mayCapture(for:)`), `=0` disables it in the app.
    static let captureAllowed: Bool = {
        if demoSignal { return true }
        if let v = ProcessInfo.processInfo.environment["DESKSET_AUDIO_CAPTURE"] { return v != "0" }
        let cliFlags = Set(CommandLineTools.modeFlags)
        return !CommandLine.arguments.dropFirst().contains { cliFlags.contains($0) }
    }()

    /// `DESKSET_AUDIO_DEMO=1`: every stream is a generated demo signal (SyntheticAudioBackend), also in
    /// command-line modes — no permission involved. `=silent`: the demo stream carries only digital silence.
    /// `=refused`: silence, with the silence watchdog's verdict already given (`MacPermission` 1), as a refused System
    /// Audio Recording shows it (renders of a visualizer's refused state).
    static let demoSignal = ["1", "silent", "refused"].contains(ProcessInfo.processInfo.environment["DESKSET_AUDIO_DEMO"] ?? "")
    static let demoSilence = ["silent", "refused"].contains(ProcessInfo.processInfo.environment["DESKSET_AUDIO_DEMO"] ?? "")
    static let demoRefused = ProcessInfo.processInfo.environment["DESKSET_AUDIO_DEMO"] == "refused"

    /// Seconds a source keeps running after its last subscriber left (skin refresh).
    var stopDelay: TimeInterval = 3
    /// Seconds between two restarts caused by device notifications (they come in bursts).
    static let restartDelay: TimeInterval = 0.3
    static let analysisInterval: TimeInterval = 1.0 / 60
    /// A source nobody has read for `idleAfter` seconds, or that has carried only digital silence for as long, is
    /// analysed at this interval instead (the levels still follow every sample: the ticks take all that arrived). It
    /// is back at `analysisInterval` within one of these once it is read again or sounds. A visualizer at rest reads
    /// its levels once a second (Spectrum, Studio VU), so it no longer keeps the analysis at 60 ticks a second.
    static let restInterval: TimeInterval = 0.25
    static let idleAfter: TimeInterval = 0.5
    /// A spectrum (FFT, bands) nobody has read for this long is not transformed (a visualizer at rest reads only its
    /// levels).
    static let spectrumIdleAfter: TimeInterval = 1
    /// Without new frames for this long the analyzers decay towards silence.
    static let silenceTimeout: TimeInterval = 0.1

    /// The engine captures (whether a skin may use it, demo signal or not, is `AudioPlugins.mayCapture(for:)`'s
    /// question).
    var capturesNothing: Bool { false }

    /// Creates the backend for a source (replaced in tests).
    var makeBackend: (AudioSourceKey) -> AudioCaptureBackend? = AudioCaptureEngine.defaultBackend
    var isCaptureAllowed = AudioCaptureEngine.captureAllowed

    /// Seconds between two looks at a stream that has carried only digital silence so far (see `silenceNote`).
    var silenceCheckInterval: TimeInterval = 10
    /// Seconds between two tries to start a source that a refused permission keeps from running (the microphone,
    /// Screen Recording before macOS 14.2): the user may allow it in System Settings at any time and macOS sends no
    /// notification, so the source is started again until it runs. 0 = never.
    var permissionRetryInterval: TimeInterval = 10
    /// The apps other than Deskset that play audio right now (HAL queue; replaced in tests): the silence watchdog's
    /// evidence. Only apps the user runs count, by the pid of the app a playing process works for (a browser's audio
    /// helper counts as the browser); daemons and agents that keep an output open (system sounds, speech, call
    /// services, audio routers) do not. See `AudioProcesses.appsRunningOutput`.
    var appsPlayingAudio: () -> Set<pid_t> = { AudioProcesses.appsRunningOutput() }
    /// While the silence watchdog's verdict stands, a look that still finds silence while an app plays takes a new
    /// tap (a permission given in System Settings may reach only a new one): the first this many seconds after the
    /// verdict, each next one the next delay after the one before. After the last, none until another app starts
    /// playing or the user leaves System Settings (`watchPermissionChanges`), which start the delays again.
    var retapDelays: [TimeInterval] = [10, 30, 60, 180, 300]
    /// Calls its argument (any thread) whenever the user may have changed a permission, such as when System Settings
    /// is left or quits: a source whose verdict stands then takes a new tap at once. Set up at the first verdict; nil
    /// watches nothing (tests, command-line modes).
    var watchPermissionChanges: ((@escaping () -> Void) -> Void)?
    /// When set, system audio (`Port=Output`) is captured only while another process plays sound: at rest there is no
    /// tap, so no purple recording indicator and no output device kept running for nothing. Its source then waits in
    /// `standby`. The shared engine uses Core Audio's process objects (macOS 14.2 and later); nil captures for as long
    /// as a source is subscribed (older systems, the demo signal, command-line modes, most tests).
    var outputActivity: AudioOutputActivity?
    /// Seconds a system-audio capture keeps running after the last other process stopped playing sound (the gap
    /// between two tracks, a browser that stops its stream a moment after the video, a quick pause).
    var standbyDelay: TimeInterval = 5
    /// Shown for a system-audio stream that stayed digitally silent over two looks while another app was playing
    /// sound: the usual sign of a refused System Audio Recording permission (macOS then delivers zeros).
    static let silenceNote = "AudioLevel hears only silence although an app is playing sound: Deskset may not be "
        + "allowed to record system audio. Allow it in System Settings → Privacy & Security → Screen & System Audio "
        + "Recording → System Audio Recording Only."

    private let analysisQueue = DispatchQueue(label: "net.deskset.audio.analysis", qos: .userInteractive)
    /// HAL queue only.
    private var sources: [AudioSourceKey: Source] = [:]
    private var systemObserver: AudioSystem.ObserverToken?

    private let statusLock = NSLock()
    private var statuses: [AudioSourceKey: AudioSourceStatus] = [:]
    /// HAL queue only. While suspended nothing captures; subscriptions are kept and capture starts again on resume.
    private var suspended = false
    /// HAL queue only: `outputActivity` is being observed (while a system-audio source exists).
    private var observingActivity = false
    /// HAL queue only: a system-audio stream has carried sound since Deskset started, so the permission was given, and
    /// a later silence while other apps run their output (a call app between calls, a paused video) is not taken for a
    /// refusal.
    private var heardSystemAudio = false
    /// HAL queue only: `watchPermissionChanges` has been set up.
    private var watchingPermissionChanges = false

    final class Source {
        let key: AudioSourceKey
        let ring = AudioRingBuffer()
        let lock = NSLock()
        private var _analyzers: [AudioAnalyzer] = []
        private var _sampleRate = 0.0
        var backend: AudioCaptureBackend?
        var timer: DispatchSourceTimer?
        var pendingStop: DispatchWorkItem?
        var pendingRestart: DispatchWorkItem?
        /// Analysis queue only.
        let scratch: UnsafeMutablePointer<Float>
        var lastAudio: TimeInterval = 0
        var lastTick: TimeInterval = 0
        /// Analysis queue: the last tick that drained a sample other than zero.
        var lastSound: TimeInterval = 0
        /// Analysis queue: the timer's interval now (`analysisInterval` or `restInterval`).
        var interval = AudioCaptureEngine.analysisInterval
        /// Analysis queue: a non-zero sample arrived since the capture started.
        var heardLocally = false
        private var _heardAudio = false
        /// HAL queue: looks in a row at a silent stream while the same app played sound (see `silenceNote`).
        var silentLooks = 0
        /// HAL queue: the apps that played at every look counted in `silentLooks`.
        var lookPlayers: Set<pid_t> = []
        /// HAL queue, while the verdict stands: new taps taken since the verdict (or since the delays started again),
        /// the uptime before which no other may be taken, and the apps seen playing meanwhile (see `retapDelays`).
        var retaps = 0
        var nextRetap: TimeInterval = 0
        var retapPlayers: Set<pid_t> = []
        /// HAL queue: the watchdog's verdict (see `silenceNote`). It outlasts the capture: a source that waits for sound
        /// (`standby`) keeps it, until a stream of this source carries sound.
        var refusalSuspected = false
        /// HAL queue: system audio waits for another process to play sound (no backend; see `outputActivity`).
        var standby = false
        /// HAL queue: the capture stops `standbyDelay` seconds after the last other process stopped playing.
        var pendingStandby: DispatchWorkItem?

        init(key: AudioSourceKey) {
            self.key = key
            scratch = .allocate(capacity: ring.capacity * AudioRingBuffer.stride)
        }

        deinit { scratch.deallocate() }

        var analyzers: [AudioAnalyzer] {
            get { lock.lock(); defer { lock.unlock() }; return _analyzers }
            set { lock.lock(); _analyzers = newValue; lock.unlock() }
        }

        var sampleRate: Double {
            get { lock.lock(); defer { lock.unlock() }; return _sampleRate }
            set { lock.lock(); _sampleRate = newValue; lock.unlock() }
        }

        /// A non-zero sample arrived since the capture started (set by the analysis queue, read by the HAL queue).
        var heardAudio: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _heardAudio }
            set { lock.lock(); _heardAudio = newValue; lock.unlock() }
        }
    }

    init() {}

    // MARK: Subscriptions (any thread)

    func subscribe(_ analyzer: AudioAnalyzer, to key: AudioSourceKey) {
        AudioHAL.queue.async { [self] in
            observeSystemIfNeeded()
            let source = sources[key] ?? {
                let s = Source(key: key)
                sources[key] = s
                return s
            }()
            source.pendingStop?.cancel()
            source.pendingStop = nil
            if !source.analyzers.contains(where: { $0 === analyzer }) { source.analyzers.append(analyzer) }
            if source.backend == nil {
                // A source waiting for sound goes on waiting.
                if !source.standby { startIfWanted(source) }
            } else if !status(for: key).running && status(for: key).message != "starting" {
                // A capture that failed (permission granted since, device back…) is retried when a skin loads or
                // refreshes.
                scheduleRestart(key)
            }
        }
    }

    /// Takes `analyzer` off its source (the source stops `stopDelay` seconds after its last analyzer left) and puts its
    /// values back to 0: nothing feeds it any more.
    func unsubscribe(_ analyzer: AudioAnalyzer) {
        AudioHAL.queue.async { [self] in
            for source in sources.values where source.analyzers.contains(where: { $0 === analyzer }) {
                source.analyzers.removeAll { $0 === analyzer }
                if source.analyzers.isEmpty { scheduleStop(source) }
                analysisQueue.async { analyzer.reset() }
            }
        }
    }

    /// Latest status of a source (a default status before it has started).
    func status(for key: AudioSourceKey) -> AudioSourceStatus {
        statusLock.lock(); defer { statusLock.unlock() }
        return statuses[key] ?? AudioSourceStatus()
    }

    /// Keys of the sources that exist (tests, diagnostics). HAL queue round trip.
    func activeSourceKeys() -> [AudioSourceKey] {
        AudioHAL.queue.sync { Array(sources.keys) }
    }

    /// Seconds between the analysis ticks of a source now (`analysisInterval` or `restInterval`; tests).
    func pace(for key: AudioSourceKey) -> TimeInterval? {
        guard let source = AudioHAL.queue.sync(execute: { sources[key] }) else { return nil }
        return analysisQueue.sync { source.interval }
    }

    /// Waits until queued subscription work has run (tests).
    func drain() {
        AudioHAL.queue.sync {}
        analysisQueue.sync {}
    }

    /// The app pauses skin updates (Mac asleep, displays asleep, another user's session in front): every capture
    /// stops — no audio-recording indicator, no analysis wake-ups — and starts again when `suspended` is false.
    /// Subscriptions are kept meanwhile; new ones wait for the resume.
    func setSuspended(_ value: Bool) {
        AudioHAL.queue.async { [self] in
            guard suspended != value else { return }
            suspended = value
            for source in sources.values {
                source.pendingRestart?.cancel()
                source.pendingRestart = nil
                source.pendingStandby?.cancel()
                source.pendingStandby = nil
                if value {
                    if source.backend != nil { stop(source) }
                    source.standby = false
                } else if source.backend == nil && !source.analyzers.isEmpty {
                    startIfWanted(source)
                }
            }
        }
    }

    /// Whether the source of `key` is waiting for another app to play sound (HAL queue round trip; tests).
    func isWaitingForSound(_ key: AudioSourceKey) -> Bool {
        AudioHAL.queue.sync { sources[key]?.standby ?? false }
    }

    /// Whether capture is suspended (HAL queue round trip; tests).
    var isSuspended: Bool { AudioHAL.queue.sync { suspended } }

    // MARK: Start / stop (HAL queue)

    private func setStatus(_ status: AudioSourceStatus, for key: AudioSourceKey) {
        statusLock.lock()
        statuses[key] = status
        statusLock.unlock()
    }

    /// A backend's status with what the engine knows about the source besides: the watchdog's verdict.
    private func withVerdict(_ status: AudioSourceStatus, of source: Source) -> AudioSourceStatus {
        guard source.refusalSuspected else { return status }
        var s = status
        s.refusalSuspected = true
        s.permissionNote = s.permissionNote ?? AudioCaptureEngine.silenceNote
        return s
    }

    /// Whether the source's capture waits for another process to play sound (`outputActivity`).
    private func waitsForSound(_ key: AudioSourceKey) -> Bool {
        key.kind == .output && outputActivity != nil
    }

    /// Starts a subscribed source; system audio (with `outputActivity`) only while another process plays sound, and
    /// otherwise the source waits for that in `standby`.
    private func startIfWanted(_ source: Source) {
        guard !suspended else { return }
        guard waitsForSound(source.key), let activity = outputActivity, isCaptureAllowed else {
            start(source)
            return
        }
        observeActivityIfNeeded()
        if activity.othersPlay() {
            start(source)
        } else {
            enterStandby(source)
        }
    }

    /// Stops the capture of a source that waits for sound: its status says so (`Type=DeviceStatus` 1, and
    /// `Type=MacPermission` 1 while the watchdog's verdict stands) and its values are 0.
    private func enterStandby(_ source: Source) {
        source.pendingStandby?.cancel()
        source.pendingStandby = nil
        if source.backend != nil { stop(source) }
        source.standby = true
        var status = self.status(for: source.key)
        status.running = false
        status.standby = true
        status.message = nil
        status.refusalSuspected = false
        status.permissionNote = nil
        status.missingPermission = nil
        status.permissionUndecided = false
        setStatus(withVerdict(status, of: source), for: source.key)
    }

    /// Another process started or stopped playing sound: sources waiting for it start at once; running ones stop
    /// `standbyDelay` seconds after the last one stopped (unless one plays again by then).
    private func outputActivityChanged() {
        guard let activity = outputActivity, !suspended else { return }
        let playing = activity.othersPlay()
        for source in sources.values where waitsForSound(source.key) && !source.analyzers.isEmpty {
            if playing {
                source.pendingStandby?.cancel()
                source.pendingStandby = nil
                if source.backend == nil { start(source) }
            } else if source.backend != nil && source.pendingStandby == nil {
                let item = DispatchWorkItem { [weak self, weak source] in
                    guard let self, let source, self.sources[source.key] === source else { return }
                    source.pendingStandby = nil
                    guard !self.suspended, source.backend != nil, !activity.othersPlay() else { return }
                    self.enterStandby(source)
                }
                source.pendingStandby = item
                if standbyDelay <= 0 {
                    AudioHAL.queue.async(execute: item)
                } else {
                    AudioHAL.queue.asyncAfter(deadline: .now() + standbyDelay, execute: item)
                }
            }
        }
    }

    private func observeActivityIfNeeded() {
        guard !observingActivity, let activity = outputActivity else { return }
        observingActivity = true
        activity.observe { [weak self] in self?.outputActivityChanged() }
    }

    private func stopObservingActivityIfUnused() {
        guard observingActivity, !sources.keys.contains(where: waitsForSound) else { return }
        observingActivity = false
        outputActivity?.stopObserving()
    }

    private func start(_ source: Source) {
        source.pendingStandby?.cancel()
        source.pendingStandby = nil
        source.standby = false
        guard !suspended else { return }
        guard isCaptureAllowed else {
            setStatus(AudioSourceStatus(message: "audio capture is off in command-line mode"), for: source.key)
            return
        }
        guard let backend = makeBackend(source.key) else {
            setStatus(AudioSourceStatus(message: "audio capture is not available on this macOS version"),
                      for: source.key)
            return
        }
        source.ring.clear()
        source.heardAudio = false
        source.silentLooks = 0
        source.lookPlayers = []
        analysisQueue.async { [weak source] in source?.heardLocally = false }
        let key = source.key
        let events = AudioBackendEvents(
            restart: { [weak self] in AudioHAL.queue.async { self?.scheduleRestart(key) } },
            status: { [weak self, weak backend] status in
                AudioHAL.queue.async {
                    guard let self, let backend, let s = self.sources[key], s.backend === backend else { return }
                    s.sampleRate = status.sampleRate
                    self.setStatus(self.withVerdict(status, of: s), for: key)
                    if status.running && s.timer == nil { self.startTimer(s) }
                }
            })
        source.backend = backend
        let status = backend.start(ring: source.ring, events: events)
        source.sampleRate = status.sampleRate
        setStatus(withVerdict(status, of: source), for: source.key)
        // No timer while nothing is captured (permission denied, no device): no wake-ups for nothing.
        if status.running { startTimer(source) }
        if backend.deliversSilenceWhenRefused { scheduleSilenceLook(source, backend: backend, remaining: 60) }
        if !status.running, status.permissionNote != nil { schedulePermissionRetry(source, backend: backend) }
    }

    /// Starts a source again `permissionRetryInterval` seconds after a refused permission kept it from running, as
    /// long as it is still wanted; a source that runs then gets a status without `permissionNote` (and the skins
    /// take their note back). Still refused: tried again later. Backends ask for a permission only once per run, so
    /// this never shows a prompt again.
    private func schedulePermissionRetry(_ source: Source, backend: AudioCaptureBackend) {
        guard permissionRetryInterval > 0 else { return }
        AudioHAL.queue.asyncAfter(deadline: .now() + permissionRetryInterval) { [weak self, weak source, weak backend] in
            guard let self, let source, let backend, source.backend === backend, !self.suspended,
                  self.sources[source.key] === source, !source.analyzers.isEmpty,
                  !self.status(for: source.key).running else { return }
            self.stop(source)
            self.startIfWanted(source)
        }
    }

    /// Looks every `silenceCheckInterval` seconds (at most `remaining` more times) whether a stream that may be
    /// silenced by a refused permission has carried any sound yet. Two looks in a row with nothing heard while the
    /// same app played audio (`appsPlayingAudio`) are the verdict: `permissionNote` and `refusalSuspected`
    /// (`Type=MacPermission` 1). Not once a system-audio stream has carried sound since Deskset started (the permission
    /// was given then). Sound clears the verdict. While it stands, a look that still finds silence while an app plays
    /// may start the capture again, so a permission granted in System Settings reaches a new tap: after the delays of
    /// `retapDelays`, and at once when the user leaves System Settings. The tap is kept between those.
    private func scheduleSilenceLook(_ source: Source, backend: AudioCaptureBackend, remaining: Int) {
        guard remaining > 0, silenceCheckInterval > 0 else { return }
        AudioHAL.queue.asyncAfter(deadline: .now() + silenceCheckInterval) { [weak self, weak source, weak backend] in
            guard let self, let source, let backend, source.backend === backend, !self.suspended else { return }
            guard !source.heardAudio else {
                self.noteSound(source)
                return
            }
            let players = self.appsPlayingAudio()
            if players.isEmpty {
                source.silentLooks = 0
                source.lookPlayers = []
            } else if source.silentLooks > 0 && !source.lookPlayers.isDisjoint(with: players) {
                source.silentLooks += 1
                source.lookPlayers.formIntersection(players)
            } else {
                source.silentLooks = 1
                source.lookPlayers = players
            }
            let now = ProcessInfo.processInfo.systemUptime
            if source.silentLooks >= 2 && !source.refusalSuspected && !self.heardSystemAudio {
                source.refusalSuspected = true
                self.restartRetaps(source, players: players, now: now)
                self.setStatus(self.withVerdict(self.status(for: source.key), of: source), for: source.key)
                self.watchPermissionChangesIfNeeded()
            } else if source.refusalSuspected && !players.isEmpty {
                // Another app started playing since the delays started: they start again.
                if !players.isSubset(of: source.retapPlayers) {
                    self.restartRetaps(source, players: source.retapPlayers.union(players), now: now)
                }
                // Still silent while an app plays: a permission given since may only reach a new tap, so the
                // capture starts again (the verdict stays until a tap carries sound, and the new tap looks again).
                if source.retaps < self.retapDelays.count && now >= source.nextRetap - self.silenceCheckInterval / 2 {
                    source.retaps += 1
                    let next = self.retapDelays[min(source.retaps, self.retapDelays.count - 1)]
                    source.nextRetap = now + next
                    self.scheduleRestart(source.key)
                    return
                }
            }
            // Keeps looking after the verdict, so it is cleared once sound arrives.
            let remainingNext = source.refusalSuspected ? remaining : remaining - 1
            self.scheduleSilenceLook(source, backend: backend, remaining: remainingNext)
        }
    }

    /// Starts `retapDelays` again for a source whose verdict stands (HAL queue).
    private func restartRetaps(_ source: Source, players: Set<pid_t>, now: TimeInterval) {
        source.retaps = 0
        source.nextRetap = now + (retapDelays.first ?? 0)
        source.retapPlayers = players
    }

    /// Sets up `watchPermissionChanges` once (HAL queue).
    private func watchPermissionChangesIfNeeded() {
        guard !watchingPermissionChanges, let watch = watchPermissionChanges else { return }
        watchingPermissionChanges = true
        watch { [weak self] in AudioHAL.queue.async { self?.permissionMayHaveChanged() } }
    }

    /// The user may have changed a permission (left System Settings): a source whose verdict stands takes a new tap at
    /// once if it captures, and `retapDelays` start again (HAL queue; tests call it directly).
    func permissionMayHaveChanged() {
        let now = ProcessInfo.processInfo.systemUptime
        for source in sources.values where source.refusalSuspected {
            restartRetaps(source, players: [], now: now)
            if source.backend != nil && !suspended { scheduleRestart(source.key) }
        }
    }

    /// A stream of `source` carried sound: the permission is there. Clears the watchdog's verdict (HAL queue).
    private func noteSound(_ source: Source) {
        guard source.heardAudio else { return }
        if source.key.kind == .output { heardSystemAudio = true }
        var status = self.status(for: source.key)
        let hadVerdict = source.refusalSuspected || status.refusalSuspected
        source.refusalSuspected = false
        source.retaps = 0
        source.retapPlayers = []
        if hadVerdict || status.permissionNote == AudioCaptureEngine.silenceNote {
            status.refusalSuspected = false
            if status.permissionNote == AudioCaptureEngine.silenceNote { status.permissionNote = nil }
            setStatus(status, for: source.key)
        }
    }

    private func stop(_ source: Source) {
        noteSound(source)
        source.timer?.cancel()
        source.timer = nil
        source.backend?.stop()
        source.backend = nil
        let analyzers = source.analyzers
        analysisQueue.async { for a in analyzers { a.reset() } }
        var status = self.status(for: source.key)
        status.running = false
        setStatus(status, for: source.key)
    }

    private func scheduleStop(_ source: Source) {
        source.pendingStop?.cancel()
        let item = DispatchWorkItem { [weak self, weak source] in
            guard let self, let source, source.analyzers.isEmpty else { return }
            self.stop(source)
            source.pendingRestart?.cancel()
            source.pendingStandby?.cancel()
            source.pendingStandby = nil
            source.standby = false
            self.sources[source.key] = nil
            self.statusLock.lock()
            self.statuses[source.key] = nil
            self.statusLock.unlock()
            self.stopObservingActivityIfUnused()
        }
        source.pendingStop = item
        if stopDelay <= 0 {
            AudioHAL.queue.async(execute: item)
        } else {
            AudioHAL.queue.asyncAfter(deadline: .now() + stopDelay, execute: item)
        }
    }

    private func scheduleRestart(_ key: AudioSourceKey) {
        guard let source = sources[key] else { return }
        source.pendingRestart?.cancel()
        let item = DispatchWorkItem { [weak self, weak source] in
            guard let self, let source, self.sources[key] === source else { return }
            self.stop(source)
            if !source.analyzers.isEmpty { self.startIfWanted(source) }
        }
        source.pendingRestart = item
        AudioHAL.queue.asyncAfter(deadline: .now() + AudioCaptureEngine.restartDelay, execute: item)
    }

    /// Default device changed or devices came and went: restart the sources whose device is no longer right.
    private func observeSystemIfNeeded() {
        guard systemObserver == nil, isCaptureAllowed, !AudioCaptureEngine.demoSignal else { return }
        systemObserver = AudioSystem.shared.addObserver { [weak self] in
            guard let self else { return }
            // A source waiting for sound has no device to check: it picks the current one when it starts.
            for (key, source) in self.sources where !source.analyzers.isEmpty && !source.standby {
                let wanted = AudioCaptureEngine.resolveDevice(key)
                if source.backend == nil || source.backend?.deviceID != wanted?.device { self.scheduleRestart(key) }
            }
        }
    }

    // MARK: Analysis

    private func startTimer(_ source: Source) {
        source.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
        let interval = AudioCaptureEngine.analysisInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(4))
        // Queued before the first tick on the same serial queue (a previous timer's tick may still be running).
        analysisQueue.async { [weak source] in
            let now = ProcessInfo.processInfo.systemUptime
            source?.lastAudio = now
            source?.lastTick = now
            source?.lastSound = now
            source?.interval = interval
        }
        timer.setEventHandler { [weak source, weak timer] in
            guard let source else { return }
            AudioCaptureEngine.tick(source, timer: timer)
        }
        source.timer = timer
        timer.resume()
    }

    /// One analysis step (analysis queue): drain the ring, feed or decay the analyzers, then choose the pace of the
    /// next steps (`restInterval`).
    /// `timer`: the source's timer, rescheduled here (the HAL queue owns `source.timer`).
    static func tick(_ source: Source, timer: DispatchSourceTimer? = nil,
                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let (frames, channels) = source.ring.read(into: source.scratch, maxFrames: source.ring.capacity)
        let analyzers = source.analyzers
        let reads = analyzers.map(\.readTimes)
        let lastSpectrumRead = reads.map(\.spectrum).max() ?? 0
        let rate = source.sampleRate
        if frames > 0, channels > 0, rate > 0 {
            var peak: Float = 0
            vDSP_maxmgv(source.scratch, 1, &peak, vDSP_Length(frames * AudioRingBuffer.stride))
            if peak > 0 {
                source.lastSound = now
                if !source.heardLocally {
                    source.heardLocally = true
                    source.heardAudio = true
                }
            }
            // A spectrum that was never read yet is transformed: the first reader finds it ready.
            let spectrumWanted = lastSpectrumRead == 0 || now - lastSpectrumRead < spectrumIdleAfter
            for a in analyzers {
                a.process(source.scratch, stride: AudioRingBuffer.stride, frames: frames, channels: channels,
                          sampleRate: rate, analyzesSpectrum: spectrumWanted)
            }
            source.lastAudio = now
        } else if now - source.lastAudio > silenceTimeout {
            let seconds = now - source.lastTick
            for a in analyzers { a.decay(seconds: seconds) }
        }
        source.lastTick = now
        let lastRead = reads.map(\.any).max() ?? 0
        let resting = now - lastRead > idleAfter || now - source.lastSound > idleAfter
        let interval = resting ? restInterval : analysisInterval
        if interval != source.interval, let timer {
            source.interval = interval
            timer.schedule(deadline: .now() + interval, repeating: interval,
                           leeway: resting ? .milliseconds(50) : .milliseconds(4))
        }
    }

    // MARK: Devices

    /// The device a source should capture: `ID` matched as a UID, then as a name (case-insensitive); otherwise the
    /// default device (`fallback` true when an ID was given but not found — Windows IDs never exist on a Mac).
    static func resolveDevice(_ key: AudioSourceKey) -> (device: AudioObjectID, fallback: Bool)? {
        let input: Bool
        switch key.kind {
        case .output, .process: input = false
        case .input: input = true
        }
        if let wanted = key.deviceID?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            let candidates = AudioHAL.deviceIDs().filter { AudioHAL.channelCount(of: $0, input: input) > 0 }
            if let d = candidates.first(where: { AudioHAL.uid(of: $0) == wanted }) { return (d, false) }
            if let d = candidates.first(where: {
                AudioHAL.name(of: $0)?.caseInsensitiveCompare(wanted) == .orderedSame
            }) { return (d, false) }
            return AudioHAL.defaultDevice(input: input).map { ($0, true) }
        }
        return AudioHAL.defaultDevice(input: input).map { ($0, false) }
    }

    static func defaultBackend(_ key: AudioSourceKey) -> AudioCaptureBackend? {
        if demoSignal { return SyntheticAudioBackend() }
        switch key.kind {
        case .input:
            return InputDeviceBackend(key: key)
        case .output, .process:
            if #available(macOS 14.2, *), ProcessInfo.processInfo.environment["DESKSET_AUDIO_FORCE_SCK"] == nil {
                return ProcessTapBackend(key: key)
            }
            if case .process = key.kind { return nil }
            return ScreenCaptureAudioBackend(key: key)
        }
    }
}
