import AppKit
import CoreAudio
import Foundation
import DesksetCore

// `Plugin=AppVolume` — third-party plugin (public README: https://github.com/khanhas/AppVolumePlugin, usage
// section only). Windows gives every app its own volume in the mixer; macOS has no per-app volume. What Deskset does:
// - Apps: Core Audio's list of audio client processes (macOS 14.2+). An "app" is a Dock app that uses Core Audio,
//   plus — with `IgnoreSystemSound=0` — any other process currently playing (system sounds, helpers). Deskset itself
//   and `ExcludeApp=a.exe;b` (matched with or without ".exe", case-insensitive) are left out. Before macOS 14.2 the
//   list is empty.
// - Parent: number = number of apps, string = default output device name. Child (`Parent=`, `Index` 1-based or
//   `AppName`): `NumberType`/`NumType` Volume (always 1.0: macOS apps have no own volume) or Peak (0…1, from a
//   process tap of that app — needs the System Audio Recording permission; 0 outside skin windows); `StringType`
//   FileName (executable name, e.g. "Spotify") or FilePath (executable path).
// - Commands: Update (re-read options); Mute / UnMute / ToggleMute mute one app with a muted process tap
//   (macOS 14.2+; the app plays again when unmuted or when Deskset quits); SetVolume is not possible (logged).
// - Section variables on the parent: GetVolumeFromIndex(x), GetPeakFromIndex(x), GetFileNameFromIndex(x),
//   GetFilePathFromIndex(x), GetVolumeFromAppName(name), GetPeakFromAppName(name).

struct AudioApp: Equatable {
    var pid: pid_t
    /// Executable name ("Spotify").
    var fileName: String
    /// Executable path.
    var filePath: String
    var bundleID: String
    var isRegularApp: Bool
    var isPlaying: Bool

    /// `AppName=Spotify.exe` / `spotify` / the bundle ID.
    func matches(_ name: String) -> Bool {
        var n = name.trimmingCharacters(in: .whitespaces)
        if n.lowercased().hasSuffix(".exe") { n = String(n.dropLast(4)) }
        guard !n.isEmpty else { return false }
        return fileName.caseInsensitiveCompare(n) == .orderedSame || bundleID.caseInsensitiveCompare(n) == .orderedSame
            || (fileName as NSString).deletingPathExtension.caseInsensitiveCompare(n) == .orderedSame
    }
}

/// Cached list of audio apps, refreshed in the background at most every 2 s while skins read it; per-app mute
/// through muted process taps.
///
/// `muted` is what skins read: it changes at once when a command arrives, and the taps follow on the HAL queue. A
/// list refresh only drops the apps that quit (it never rebuilds `muted` from the taps: a refresh queued just before a
/// Mute would otherwise forget the app, and the next ToggleMute would mute it again instead of unmuting it).
final class AudioAppCatalog {
    static let shared = AudioAppCatalog()
    static let refreshInterval: TimeInterval = 2

    /// Reads the audio client processes (HAL queue; replaced in tests).
    var readApps: () -> [AudioApp] = { AudioAppCatalog.systemApps() }
    /// Creates a muted tap of one process, or destroys one (HAL queue; replaced in tests).
    var makeMuteTap: (pid_t) -> AudioObjectID? = { AudioAppCatalog.systemMuteTap($0) }
    var destroyTap: (AudioObjectID) -> Void = { tap in
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    }
    var captureAllowed: () -> Bool = { AudioCaptureEngine.shared.isCaptureAllowed }

    private let lock = NSLock()
    private var apps: [AudioApp] = []
    private var muted: Set<pid_t> = []
    private var lastRefresh: TimeInterval = -1_000
    private var refreshPending = false
    /// HAL queue only: tap per muted app.
    private var muteTaps: [pid_t: AudioObjectID] = [:]

    /// All audio client processes (filtered by the measures). Starts a background refresh when stale.
    func list() -> [AudioApp] {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let result = apps
        let stale = now - lastRefresh > AudioAppCatalog.refreshInterval && !refreshPending
        if stale { refreshPending = true }
        lock.unlock()
        if stale { scheduleRefresh() }
        return result
    }

    func isMuted(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return muted.contains(pid)
    }

    /// Re-reads the app list on the HAL queue.
    func scheduleRefresh() {
        AudioHAL.queue.async { self.refresh() }
    }

    private func refresh() {
        let own = ProcessInfo.processInfo.processIdentifier
        let result = readApps().filter { $0.pid != own && $0.pid > 0 }
        // Taps of apps that quit go away.
        let alive = Set(result.map(\.pid))
        for (pid, tap) in muteTaps where !alive.contains(pid) {
            destroyTap(tap)
            muteTaps[pid] = nil
        }
        lock.lock()
        apps = result
        muted = muted.filter { alive.contains($0) }
        lastRefresh = ProcessInfo.processInfo.systemUptime
        refreshPending = false
        lock.unlock()
    }

    /// Core Audio's client processes with their executable names (HAL queue). Empty before macOS 14.2.
    static func systemApps() -> [AudioApp] {
        AudioProcesses.list().map { p -> AudioApp in
            let app = NSRunningApplication(processIdentifier: p.pid)
            let path = app?.executableURL?.path ?? AudioAppCatalog.executablePath(p.pid) ?? ""
            let file = path.isEmpty ? (app?.localizedName ?? "pid \(p.pid)") : (path as NSString).lastPathComponent
            return AudioApp(pid: p.pid, fileName: file, filePath: path, bundleID: p.bundleID,
                            isRegularApp: app?.activationPolicy == .regular, isPlaying: p.isRunningOutput)
        }
    }

    /// A private tap that silences one process while it exists (macOS 14.2+).
    static func systemMuteTap(_ pid: pid_t) -> AudioObjectID? {
        guard #available(macOS 14.2, *), let object = AudioProcesses.object(for: pid) else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: [object])
        description.name = "Deskset AppVolume mute"
        description.isPrivate = true
        description.muteBehavior = .muted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else { return nil }
        return tap
    }

    static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    /// Mutes or unmutes one app (macOS 14.2+). Returns a message when it cannot.
    func setMuted(_ pid: pid_t, _ mute: Bool) -> String? {
        setMuted(pid) { _ in mute }
    }

    /// Mutes the app when it is not muted and the other way round, as one step: skins on different threads may toggle
    /// it at the same time (docs/skin-threading.md §4.7), and each toggle must count.
    func toggleMuted(_ pid: pid_t) -> String? {
        setMuted(pid) { !$0 }
    }

    /// `decide` gets whether the app is muted and returns whether it should be. The decision and the HAL work are
    /// queued under the lock, so the HAL queue carries out concurrent changes in the order they were decided.
    private func setMuted(_ pid: pid_t, _ decide: (Bool) -> Bool) -> String? {
        guard #available(macOS 14.2, *) else { return "muting one app needs macOS 14.2 or later" }
        guard captureAllowed() else { return "audio capture is off in command-line mode" }
        lock.lock()
        defer { lock.unlock() }
        let mute = decide(muted.contains(pid))
        if mute { muted.insert(pid) } else { muted.remove(pid) }
        AudioHAL.queue.async {
            if mute {
                guard self.muteTaps[pid] == nil else { return }
                if let tap = self.makeMuteTap(pid) {
                    self.muteTaps[pid] = tap
                } else {
                    AudioPermissions.logOnce("AppVolume: could not mute process \(pid)")
                    self.lock.lock()
                    self.muted.remove(pid)
                    self.lock.unlock()
                }
            } else if let tap = self.muteTaps.removeValue(forKey: pid) {
                self.destroyTap(tap)
            }
        }
        return nil
    }
}

final class AppVolumeMeasure: Measure, SectionVariableFunctions {
    enum NumberType: Equatable { case volume, peak }
    enum StringType: Equatable { case fileName, filePath }

    private(set) var parentName = ""
    private(set) var ignoreSystemSound = true
    private(set) var excluded: [String] = []
    private(set) var index = 0
    private(set) var appName = ""
    private(set) var numberType = NumberType.volume
    private(set) var stringType = StringType.fileName
    private(set) var pluginString: String?

    /// Replaced in tests.
    var catalog: () -> [AudioApp] = { AudioAppCatalog.shared.list() }
    var engine = AudioCaptureEngine.shared
    /// Whether the skin may tap an app for its peak: see `AudioPlugins.mayCapture(for:)`.
    var mayCapture: (Skin) -> Bool = { AudioPlugins.mayCapture(for: $0) }
    var parentLookup: ((String) -> AppVolumeMeasure?)?
    var deviceName: () -> String = { AudioSystem.shared.snapshot().output.name }

    /// Peak analyzer of the app this child follows (NumberType=Peak).
    private var peakAnalyzer: (pid: pid_t, analyzer: AudioAnalyzer)?
    private var loggedMessages: Set<String> = []

    required init(name: String, section: IniSection, skin: Skin, type: String) {
        super.init(name: name, section: section, skin: skin, type: type)
    }

    deinit {
        if let peakAnalyzer { engine.unsubscribe(peakAnalyzer.analyzer) }
    }

    override func readMeasureOptions() {
        parentName = string("Parent").trimmingCharacters(in: .whitespaces)
        ignoreSystemSound = bool("IgnoreSystemSound", true)
        excluded = string("ExcludeApp").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        index = int("Index", 0)
        appName = string("AppName").trimmingCharacters(in: .whitespaces)
        let number = (option("NumberType") ?? option("NumType") ?? "Volume").trimmingCharacters(in: .whitespaces)
        numberType = number.lowercased() == "peak" ? .peak : .volume
        stringType = string("StringType", "FileName").trimmingCharacters(in: .whitespaces).lowercased() == "filepath"
            ? .filePath : .fileName
    }

    /// The parent's filtered app list.
    func apps() -> [AudioApp] {
        AppVolumeMeasure.filter(catalog(), ignoreSystemSound: ignoreSystemSound, excluded: excluded)
    }

    static func filter(_ all: [AudioApp], ignoreSystemSound: Bool, excluded: [String]) -> [AudioApp] {
        all.filter { app in
            (app.isRegularApp || (!ignoreSystemSound && app.isPlaying)) && !excluded.contains { app.matches($0) }
        }
    }

    private func parent() -> AppVolumeMeasure? {
        if parentName.isEmpty { return self }
        if let parentLookup { return parentLookup(parentName) }
        return skin.measure(named: parentName) as? AppVolumeMeasure
    }

    /// The app a child follows: `AppName` first, else `Index` (1-based).
    func selectedApp() -> AudioApp? {
        guard let parent = parent(), parent !== self else { return nil }
        let list = parent.apps()
        if !appName.isEmpty { return list.first { $0.matches(appName) } }
        guard index >= 1, index <= list.count else { return nil }
        return list[index - 1]
    }

    override func computeValue() -> Double {
        if parentName.isEmpty {
            let count = apps().count
            let text = deviceName()
            pluginString = text
            setPluginString(text)
            return Double(count)
        }
        guard parent() != nil else {
            logOnce("[\(name)] AppVolume: Parent=\(parentName) is not an AppVolume measure")
            pluginString = ""
            setPluginString("")
            return 0
        }
        let app = selectedApp()
        let text = app.map { stringType == .filePath ? $0.filePath : $0.fileName } ?? ""
        pluginString = text
        setPluginString(text)
        guard let app else {
            releasePeak()
            return 0
        }
        switch numberType {
        case .volume:
            releasePeak()
            return AudioAppCatalog.shared.isMuted(app.pid) ? 0 : 1
        case .peak:
            return peak(of: app.pid)
        }
    }

    private func peak(of pid: pid_t) -> Double {
        if let current = peakAnalyzer, current.pid == pid { return current.analyzer.peak(.sum) }
        releasePeak()
        // A skin outside a skin window (`--render`) taps no app.
        guard mayCapture(skin) else { return 0 }
        var settings = AudioAnalysisSettings()
        settings.peakAttack = 0
        settings.peakDecay = 300
        let analyzer = AudioAnalyzer(settings: settings)
        engine.subscribe(analyzer, to: AudioSourceKey(kind: .process(pid), deviceID: nil))
        peakAnalyzer = (pid, analyzer)
        return 0
    }

    private func releasePeak() {
        if let peakAnalyzer { engine.unsubscribe(peakAnalyzer.analyzer) }
        peakAnalyzer = nil
    }

    /// Peak of an app followed by one of this parent's children (0 when none follows it).
    private func childPeak(_ pid: pid_t) -> Double {
        for m in skin.measures {
            if let child = m as? AppVolumeMeasure, child.parentName.caseInsensitiveCompare(name) == .orderedSame,
               let p = child.peakAnalyzer, p.pid == pid {
                return p.analyzer.peak(.sum)
            }
        }
        return 0
    }

    override func execute(command: String) {
        let parts = command.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: { $0 == " " })
        let verb = parts.first.map { $0.lowercased() } ?? ""
        if verb == "update" {
            readOptions()
            return
        }
        guard !parentName.isEmpty else {
            logOnce("[\(name)] AppVolume: \(command) only works on child measures")
            return
        }
        guard let app = selectedApp() else {
            logOnce("[\(name)] AppVolume: no app to control")
            return
        }
        var problem: String?
        switch verb {
        case "mute": problem = AudioAppCatalog.shared.setMuted(app.pid, true)
        case "unmute": problem = AudioAppCatalog.shared.setMuted(app.pid, false)
        case "togglemute": problem = AudioAppCatalog.shared.toggleMuted(app.pid)
        case "setvolume": problem = "per-app volume does not exist on macOS (Mute / UnMute work)"
        default: problem = "unknown command \"\(command)\""
        }
        if let problem { logOnce("[\(name)] AppVolume: \(problem)") }
    }

    // MARK: Section variables (parent)

    func sectionVariableFunction(_ call: String) -> String? {
        guard let (function, argument) = AppVolumeMeasure.parseCall(call) else { return nil }
        let list = apps()
        func app(index: String) -> AudioApp? {
            guard let i = Int(index.trimmingCharacters(in: .whitespaces)), i >= 1, i <= list.count else { return nil }
            return list[i - 1]
        }
        func app(name: String) -> AudioApp? { list.first { $0.matches(name) } }
        func volume(_ a: AudioApp?) -> String {
            guard let a else { return "0" }
            return AudioAppCatalog.shared.isMuted(a.pid) ? "0" : "1"
        }
        switch function.lowercased() {
        case "getvolumefromindex": return volume(app(index: argument))
        case "getvolumefromappname": return volume(app(name: argument))
        case "getpeakfromindex": return app(index: argument).map { AppVolumeMeasure.plain(childPeak($0.pid)) } ?? "0"
        case "getpeakfromappname": return app(name: argument).map { AppVolumeMeasure.plain(childPeak($0.pid)) } ?? "0"
        case "getfilenamefromindex": return app(index: argument)?.fileName ?? ""
        case "getfilepathfromindex": return app(index: argument)?.filePath ?? ""
        default: return nil
        }
    }

    /// `Name(argument)` → (Name, argument without surrounding quotes).
    static func parseCall(_ call: String) -> (String, String)? {
        let t = call.trimmingCharacters(in: .whitespaces)
        guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else { return nil }
        let function = String(t[..<open]).trimmingCharacters(in: .whitespaces)
        var argument = String(t[t.index(after: open)..<t.index(before: t.endIndex)]).trimmingCharacters(in: .whitespaces)
        if argument.count >= 2, let f = argument.first, f == argument.last, f == "\"" || f == "'" {
            argument = String(argument.dropFirst().dropLast())
        }
        return function.isEmpty ? nil : (function, argument)
    }

    static func plain(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.6f", v)
    }

    private func logOnce(_ message: String) {
        guard loggedMessages.count < 50, loggedMessages.insert(message).inserted else { return }
        skin.log(message, level: .notice)
    }
}
