import AppKit
import DesksetCore

// Media, network-info and UI plugins, implemented natively for macOS (clean-room, from the public documentation
// only; the notes on every Mac-vs-Windows difference are in docs/compat/media-ui.md):
//   NowPlaying (measure and plugin), the deprecated iTunesPlugin, WebNowPlaying, MediaKey  → Plugins/Media
//   WiFiStatus, InputText, FrostedGlass, Chameleon, IsFullScreen, GetActiveTitle, SysColor → Plugins/UI

/// Registers the media / UI plugin measures with `MeasureRegistry`. Call once at app start (menu bar app,
/// `--render` and `--self-test`), before any skin loads.
enum MediaUIPlugins {
    private static var registered = false

    /// Built-in measures that "were previously a plugin": registered both as `Measure=X` and as `Measure=Plugin` +
    /// `Plugin=X`.
    static let measureTypes: [(name: String, type: Measure.Type)] = [
        ("NowPlaying", NowPlayingMeasure.self),
        ("WiFiStatus", WiFiStatusMeasure.self),
        ("MediaKey", MediaKeyMeasure.self),
    ]

    /// Plugins only (Rainmeter's own and third-party).
    static let pluginTypes: [(name: String, type: Measure.Type)] = [
        ("iTunesPlugin", ITunesMeasure.self),
        ("iTunes", ITunesMeasure.self),
        ("WebNowPlaying", WebNowPlayingMeasure.self),
        ("InputText", InputTextMeasure.self),
        ("FrostedGlass", FrostedGlassMeasure.self),
        ("Chameleon", ChameleonMeasure.self),
        ("IsFullScreen", IsFullScreenMeasure.self),
        ("GetActiveTitle", ActiveTitleMeasure.self),
        ("SysColor", SysColorMeasure.self),
    ]

    static func register() {
        guard !registered else { return }
        registered = true
        for entry in measureTypes {
            MeasureRegistry.registerMeasure(entry.name, entry.type)
            MeasureRegistry.registerPlugin(entry.name, entry.type)
        }
        for entry in pluginTypes { MeasureRegistry.registerPlugin(entry.name, entry.type) }
    }

    /// Plugin names registered by `register()` (lowercased, for tests and the compatibility notes).
    static let pluginNames = (measureTypes + pluginTypes).map { MeasureRegistry.normalizedPluginName($0.name) }
    /// `Measure=` names registered by `register()` (lowercased).
    static let measureNames = measureTypes.map { $0.name.lowercased() }
}

// MARK: - Plugin measure base

/// Base of the app-side plugin measures: a number plus an optional string of their own.
///
/// `publishString` keeps the string in `pluginString` (for tests) and sets `Measure.rawString`, the string meters,
/// `[Measure]` section variables and IfMatch show (see `Measure.muiSetString`).
class MediaUIMeasure: Measure {
    /// The measure's own string for the current update (nil = number-only measure: meters format the number).
    private(set) var pluginString: String?

    /// True when the skin runs in the menu bar app on live data (`LiveSkinHost`: a skin window, or the Studio's own
    /// instance of the widget it edits). Plugins that need a macOS permission (Automation, Location) only act for such
    /// skins — never for `--render` or self-tests. Those that add windows ask the skin's window for them through the
    /// skin's runtime (`SkinCompanionChannel`): no plugin touches the window itself.
    var runsInApp: Bool { serviceHost is LiveSkinHost }

    /// The app host of the skin: its runtime, or the Studio's host of its own instance of the widget.
    var liveHost: LiveSkinHost? { serviceHost as? LiveSkinHost }

    func publishString(_ s: String?) {
        pluginString = s
        muiSetString(s)
    }

    /// Logs a message once per measure instance (problems that would otherwise repeat on every update).
    private var loggedOnce: Set<String> = []
    func logOnce(_ message: String, level: SkinLogLevel = .warning) {
        guard loggedOnce.count < 50, loggedOnce.insert(message).inserted else { return }
        skin.log(message, level: level)
    }
}

extension Measure {
    /// Sets the measure's own string value (`rawString`) from the app target.
    func muiSetString(_ s: String?) {
        rawString = s
    }
}

// MARK: - Small shared helpers

/// A long-lived background thread that runs jobs one after another. NSAppleScript, CoreWLAN and the Accessibility
/// API are used from one such thread each, never from the main thread (they can block for seconds).
final class MediaUIWorker {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []
    private let name: String
    private var started = false
    /// A job is running.
    private var busy = false
    /// Tests run jobs inline (synchronously, on the calling thread).
    var runsInline = false

    /// Every worker (weakly), for `waitForAll`.
    private static let all = Guarded([WeakWorker]())
    /// Jobs given to any worker so far, for `--render` in virtual time: whether delivering what the workers handed to
    /// the main thread gave them more to do.
    private static let queued = Guarded(0)
    static var jobsQueued: Int { queued.access { $0 } }

    private struct WeakWorker {
        weak var worker: MediaUIWorker?
    }

    init(name: String) {
        self.name = name
        MediaUIWorker.all.access { list in
            list.removeAll { $0.worker == nil }
            list.append(WeakWorker(worker: self))
        }
    }

    /// Waits until no job is queued or running, or until `deadline`: true when idle. Any thread but the worker's.
    @discardableResult
    func waitUntilIdle(before deadline: Date) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !jobs.isEmpty || busy {
            if !condition.wait(until: deadline) { return jobs.isEmpty && !busy }
        }
        return true
    }

    /// `waitUntilIdle` for every worker (`--render` in virtual time, before each update): true when all are idle.
    @discardableResult
    static func waitForAll(before deadline: Date) -> Bool {
        let workers = all.access { $0.compactMap(\.worker) }
        var idle = true
        for worker in workers where !worker.waitUntilIdle(before: deadline) { idle = false }
        return idle
    }

    func async(_ job: @escaping () -> Void) {
        MediaUIWorker.queued.access { $0 &+= 1 }
        if runsInline {
            job()
            return
        }
        condition.lock()
        if !started {
            started = true
            let thread = Thread { [weak self] in self?.loop() }
            thread.name = name
            thread.qualityOfService = .utility
            thread.start()
        }
        // Jobs are never dropped: callers keep "in flight" flags that only the job's completion clears, and they
        // never queue the same work twice, so the queue stays short even while a player does not answer.
        jobs.append(job)
        // Broadcast: a caller of `waitUntilIdle` may be waiting on the same condition.
        condition.broadcast()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            busy = true
            condition.unlock()
            autoreleasepool { job() }
            condition.lock()
            busy = false
            condition.broadcast()
            condition.unlock()
        }
    }
}

/// Main-thread hop that tests can make synchronous. A skin thread only ever queues: debug builds stop one that would run
/// the main thread's work inline (tests that make hops synchronous put their skins on the main thread), which in the
/// app would mean waiting for the main thread (docs/skin-threading.md §5.2).
enum MediaUIMainHop {
    static var runsInline = false

    static func async(_ block: @escaping () -> Void) {
        if runsInline {
            SkinThreadExecutor.assertNotWaiting(on: "the main thread (MediaUIMainHop runs inline)")
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    /// Runs `block` now on the main thread (or when tests make hops synchronous), else queues it there. For the
    /// commands skins give the shared centres, whose state lives on the main thread: a skin on the main thread
    /// (today every skin) sees the command carried out before its next line, as before; a skin on a thread of its own
    /// never waits for the main thread (docs/skin-threading.md §5.2).
    static func run(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else if runsInline {
            SkinThreadExecutor.assertNotWaiting(on: "the main thread (MediaUIMainHop runs inline)")
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}

extension StringProtocol {
    /// Trimmed of spaces and tabs (named to avoid clashing with other helpers in the app module).
    var muiTrimmed: String { trimmingCharacters(in: .whitespaces) }
}

/// Folder for files the plugins write (cover art, …): ~/Library/Caches/Deskset/<name>.
enum MediaUICache {
    /// Tests point this to a temporary folder.
    static var root: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Deskset", isDirectory: true)
    }()

    /// The folder's location only (asked on the main thread): writers create it on their background thread.
    static func folder(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }
}
