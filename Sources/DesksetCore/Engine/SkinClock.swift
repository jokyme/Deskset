import Foundation

// Seams for the time a skin sees (the runtime design, "same inputs on both sides"): every read of the wall clock, the
// monotonic clock and the local time zone in the engine and its plugins goes through the skin's `SkinClock`, so a run
// can be given a clock of its own — `Deskset --render --clock` steps a fixed one, a verifier drives a virtual one.
// `SkinClock.live` reads the system exactly as the engine did before, so nothing changes until someone injects one.

/// Where a skin reads the time (`Skin.skinClock`): the wall clock (`now`: the Time measure, SysInfo, MacWeather and
/// MacSun, Lua's `os.time` / `os.date`), a monotonic clock in seconds (`uptime`: rates, throttles, plugin timing and
/// Lua's `os.clock`) and the local time zone (`timeZone`).
///
/// Read on the skin's owner, like everything else reachable from the skin. Each part remembers whether it is the
/// system's own (`nowIsLive`…): Lua keeps using the C library for a part that is live, as it always did (one process
/// clock for `os.clock`, the process time zone for `os.date`).
public struct SkinClock {
    /// The wall clock.
    public var now: () -> Date {
        didSet { nowIsLive = false }
    }
    /// A monotonic clock in seconds. Only differences mean anything (the live one is the time since the Mac started).
    public var uptime: () -> TimeInterval {
        didSet { uptimeIsLive = false }
    }
    /// The local time zone: the Time measure without `TimeZone=`, SysInfo's time zone types, the weather plugins'
    /// local times, Lua's `os.date` without `!`.
    public var timeZone: () -> TimeZone {
        didSet { timeZoneIsLive = false }
    }
    /// Whether `now`, `uptime` and `timeZone` are the system's own (`live`'s).
    public private(set) var nowIsLive: Bool
    public private(set) var uptimeIsLive: Bool
    public private(set) var timeZoneIsLive: Bool

    /// True when every part is the system's own.
    public var isLive: Bool { nowIsLive && uptimeIsLive && timeZoneIsLive }

    /// A clock of its own (tests, `--render --clock`, a verifier).
    public init(now: @escaping () -> Date, uptime: @escaping () -> TimeInterval, timeZone: @escaping () -> TimeZone) {
        self.now = now
        self.uptime = uptime
        self.timeZone = timeZone
        nowIsLive = false
        uptimeIsLive = false
        timeZoneIsLive = false
    }

    private init(live: Void) {
        now = { Date() }
        uptime = { ProcessInfo.processInfo.systemUptime }
        timeZone = { TimeZone.current }
        nowIsLive = true
        uptimeIsLive = true
        timeZoneIsLive = true
    }

    /// The system's clocks: `Date()`, `ProcessInfo.systemUptime` and `TimeZone.current`, read at every call.
    public static let live = SkinClock(live: ())

    /// A clock that stands still at `date` (uptime `uptime`) in `timeZone`.
    public static func fixed(_ date: Date, timeZone: TimeZone, uptime: TimeInterval = SteppedSkinClock.defaultUptime)
        -> SkinClock {
        SkinClock(now: { date }, uptime: { uptime }, timeZone: { timeZone })
    }
}

/// A clock that moves only when told to (`Deskset --render --clock`): the wall clock is `start` plus the elapsed time,
/// the monotonic clock `startUptime` plus the elapsed time, and the time zone is fixed. `clock` is the `SkinClock` to
/// give a skin. Thread-safe.
public final class SteppedSkinClock: @unchecked Sendable {
    /// The monotonic clock at the start when none is given: a Mac that has been up for a day, so code that treats a
    /// small uptime (or 0) as "never" behaves as on a real Mac.
    public static let defaultUptime: TimeInterval = 86_400

    public let start: Date
    public let startUptime: TimeInterval
    private let lock = NSLock()
    private var elapsedSeconds: TimeInterval = 0
    private var zone: TimeZone

    public init(start: Date, timeZone: TimeZone, startUptime: TimeInterval = SteppedSkinClock.defaultUptime) {
        self.start = start
        self.startUptime = startUptime
        zone = timeZone
    }

    /// Seconds since `start` (never negative).
    public var elapsed: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return elapsedSeconds
        }
        set {
            lock.lock()
            elapsedSeconds = newValue.isFinite ? max(newValue, 0) : elapsedSeconds
            lock.unlock()
        }
    }

    public var timeZone: TimeZone {
        get {
            lock.lock()
            defer { lock.unlock() }
            return zone
        }
        set {
            lock.lock()
            zone = newValue
            lock.unlock()
        }
    }

    public func advance(by seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        lock.lock()
        elapsedSeconds += seconds
        lock.unlock()
    }

    /// The clock to give a skin; it reads this object at every call.
    public var clock: SkinClock {
        SkinClock(now: { [self] in start.addingTimeInterval(elapsed) },
                  uptime: { [self] in startUptime + elapsed },
                  timeZone: { [self] in timeZone })
    }
}
