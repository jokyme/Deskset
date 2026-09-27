import Foundation

// What the app plugs into the weather service (docs/compat/weather.md). The core default is fully offline: no
// transport, no device location, no skin counts as live — `--render`, the self-tests and the Manage window's dry runs
// never reach the network. The app installs the live environment when it launches (`WeatherService.install`).

/// Something scheduled on the weather clock; cancellable from any thread.
public protocol WeatherCancellable: AnyObject {
    func cancel()
}

/// The weather service's clock: the time now and delayed work. Virtual in tests (`VirtualWeatherClock`).
public protocol WeatherClock: AnyObject {
    func now() -> Date
    /// Runs `work` on `queue` after `seconds` (never inline).
    func schedule(after seconds: TimeInterval, on queue: DispatchQueue, _ work: @escaping () -> Void) -> WeatherCancellable
}

/// The real clock (`Date()`, dispatch timers with 10 % leeway).
public final class SystemWeatherClock: WeatherClock {
    public init() {}

    public func now() -> Date { Date() }

    private final class Timer: WeatherCancellable {
        let source: DispatchSourceTimer
        init(_ source: DispatchSourceTimer) { self.source = source }
        func cancel() { source.cancel() }
    }

    public func schedule(after seconds: TimeInterval, on queue: DispatchQueue,
                         _ work: @escaping () -> Void) -> WeatherCancellable {
        let source = DispatchSource.makeTimerSource(queue: queue)
        let delay = max(seconds, 0)
        let leeway = DispatchTimeInterval.milliseconds(Int(min(delay * 0.1, 600) * 1000))
        source.schedule(deadline: .now() + delay, leeway: leeway)
        source.setEventHandler { [weak source] in
            source?.cancel()
            work()
        }
        source.resume()
        return Timer(source)
    }
}

/// A clock that stands still until a test moves it; due work runs on its queue when `advance` passes its time.
public final class VirtualWeatherClock: WeatherClock {
    private let lock = NSLock()
    private var current: Date
    private var items: [Item] = []
    private var nextID = 0

    final class Item: WeatherCancellable {
        let id: Int
        let due: Date
        let queue: DispatchQueue
        var work: (() -> Void)?
        weak var clock: VirtualWeatherClock?
        init(id: Int, due: Date, queue: DispatchQueue, work: @escaping () -> Void) {
            self.id = id
            self.due = due
            self.queue = queue
            self.work = work
        }
        func cancel() { clock?.remove(id) }
    }

    public init(now: Date) {
        current = now
    }

    public func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func schedule(after seconds: TimeInterval, on queue: DispatchQueue,
                         _ work: @escaping () -> Void) -> WeatherCancellable {
        lock.lock()
        defer { lock.unlock() }
        nextID += 1
        let item = Item(id: nextID, due: current.addingTimeInterval(max(seconds, 0)), queue: queue, work: work)
        item.clock = self
        items.append(item)
        return item
    }

    fileprivate func remove(_ id: Int) {
        lock.lock()
        items.removeAll { $0.id == id }
        lock.unlock()
    }

    /// When the earliest pending work is due (nil: nothing is scheduled).
    public var nextDue: Date? {
        lock.lock()
        defer { lock.unlock() }
        return items.map(\.due).min()
    }

    /// Scheduled items not yet run.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }

    /// Moves the clock forward by `seconds`, running what falls due (in time order) on its queue.
    public func advance(by seconds: TimeInterval) {
        advance(to: now().addingTimeInterval(seconds))
    }

    public func advance(to date: Date) {
        while true {
            lock.lock()
            let due = items.filter { $0.due <= date }.min { $0.due != $1.due ? $0.due < $1.due : $0.id < $1.id }
            if let due {
                items.removeAll { $0.id == due.id }
                if due.due > current { current = due.due }
            } else if date > current {
                current = date
            }
            lock.unlock()
            guard let due else { return }
            if let work = due.work { due.queue.sync(execute: work) }
        }
    }
}

// MARK: - Device location

public enum DeviceLocationAuthorization: Equatable {
    case notDetermined, denied, restricted, authorized
}

public enum DeviceLocationError: Error, Equatable {
    case denied
    /// No fix (Wi-Fi off, no known networks, time-out).
    case unavailable
}

/// This Mac's location, at reduced accuracy, rounded before it leaves the source. Implemented by the app
/// (`LocationCenter`, CoreLocation on the main thread); any thread may call it.
public protocol DeviceLocationSource: AnyObject {
    var authorization: DeviceLocationAuthorization { get }
    /// A fix no older than `maxAge` seconds, if one is kept.
    func cachedFix(maxAge: TimeInterval) -> RoundedCoordinate?
    /// Asks for a fix (and for permission first, once, when the user has not decided). `completion` runs once, on any
    /// thread.
    func requestFix(_ completion: @escaping (Result<RoundedCoordinate, DeviceLocationError>) -> Void)
}

// MARK: - Environment

public struct WeatherEnvironment {
    /// Whether a skin's weather measures may reach the network or the device location: in the app, skins in skin
    /// windows (and the Studio's canvas). Everything else shows the Preview state.
    public var isLive: (Skin) -> Bool = { _ in false }
    /// `defaults WeatherEnabled` (read at every use).
    public var isEnabled: () -> Bool = { true }
    /// nil: no network at all.
    public var transport: WeatherTransport?
    public var endpoint = METNorway.endpoint
    public var userAgent = METNorway.userAgent(version: nil)
    /// Forecasts of places written in skins are cached here (never those of this Mac's location).
    public var cacheDirectory: URL?
    /// `places.tsv`; nil: place names cannot be looked up (coordinates and `auto` still work).
    public var placesTable: URL?
    public var deviceLocation: DeviceLocationSource?
    /// `Units=Auto`.
    public var preferredUnits: () -> WeatherUnits = { .metric }
    /// Whether the Mac shows 24-hour time (default time formats).
    public var uses24HourClock: () -> Bool = { WeatherEnvironment.systemUses24HourClock() }
    /// This Mac's time zone (`Location=timezone` looks up its city).
    public var localTimeZone: () -> TimeZone = { TimeZone.current }
    public var clock: WeatherClock = SystemWeatherClock()
    /// Uniform in 0..<1 (jitter, backoff spread).
    public var random: () -> Double = { Double.random(in: 0..<1) }
    /// Place lookups finish before the call returns (`--render`: the image must not depend on how fast the place
    /// table loads). Never for the app, where skins must not wait for it.
    public var waitsForLookups = false
    /// Synthetic forecasts for skins that are not live (`DESKSET_WEATHER_DEMO=1`: screenshots, thumbnails).
    public var demo = false
    /// The clock of the demo forecast (nil: the real time).
    public var demoNow: Date?
    /// Log lines of the service ("Weather: fetched (200)"); never coordinates, unless `debug`.
    public var log: (String) -> Void = { _ in }
    /// `defaults WeatherDebug`: the rounded coordinates of places written in skins in the log (this Mac's location only
    /// as "this Mac's location").
    public var debug = false

    public init() {}

    /// Offline, with nothing installed (the core default).
    public static let offline = WeatherEnvironment()

    /// The same answer as `#MACCLOCKHOURS#` (`MacRegionalSettings.clockHours`).
    public static func systemUses24HourClock(locale: Locale = .current) -> Bool {
        MacRegionalSettings.clockHours(locale: locale) == 24
    }
}
