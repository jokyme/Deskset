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

    /// True when the skin runs in the menu bar app (a real skin window). Plugins that need a macOS permission
    /// (Automation, Location) or that add windows only act for such skins — never for `--render` or self-tests.
    var runsInApp: Bool { skin.host is SkinController }

    /// The window controller of the skin, when it runs in the app.
    var controller: SkinController? { skin.host as? SkinController }

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
    /// Tests run jobs inline (synchronously, on the calling thread).
    var runsInline = false

    init(name: String) {
        self.name = name
    }

    func async(_ job: @escaping () -> Void) {
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
        condition.signal()
        condition.unlock()
    }

    private func loop() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }
}

/// Main-thread hop that tests can make synchronous.
enum MediaUIMainHop {
    static var runsInline = false

    static func async(_ block: @escaping () -> Void) {
        if runsInline {
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
