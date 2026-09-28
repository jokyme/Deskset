import Foundation

// Virtual time for skins (the runtime design, "same inputs on both sides"): an executor that runs nothing by itself.
// Its owner steps it — `advance(by:)` moves virtual time on and runs the work that falls due, `runUntilIdle()` runs
// what is due now — so a skin's update ticks, `!Delay`, ActionTimer steps, Bitmap transitions and plugin timers run in
// the same order on every run and every Mac, as fast as the machine allows, without a real wait. The skins that run on
// it read its clock (`clock`), and their background work comes back as ordinary work in its queue
// (`background`, see `BackgroundWork.swift`).

/// A `SkinExecutor` that keeps its work in one queue ordered by (due time, order of submission) and runs it only when
/// its owner says so. Used by `Deskset --render --clock` and, later, by the verifier that feeds the old engine and the
/// new runtime the same inputs.
///
/// The rules (the runtime design, "VirtualTimeExecutor"):
/// - Work runs only inside `advance(by:)` / `runUntilIdle()`, never when it is handed over: `async` is due now and runs
///   at the next `runUntilIdle()`; so is a hop back from background work (`SkinHop.post`), in the order it was posted.
/// - `async(after: d)` is due at now + max(d, 0).
/// - `timer(interval: i, …)` fires first at now + i and then, when it repeats, every i: its k-th firing is due at the
///   time it was made + k × i (computed afresh for each k, so the due times do not drift by adding up rounding
///   errors); the leeway is ignored; once cancelled it is not queued again. A repeating interval below 0.1 ms is
///   0.1 ms, as for a Foundation timer.
/// - Due times and the times steps move to lie on a grid of nanoseconds (`onGrid`): a timer's 3rd firing at 0.1-second
///   intervals and an update computed as 3 × 100 ms / 1000 are then the same moment (0.3), not 0.30000000000000004
///   and 0.3, and work due at the moment a step moves to runs in that step.
/// - `advance(by: d)` runs, in order, the work due at or before now + d, setting virtual time to each item's due time
///   before the item runs (the clock the skins read follows); work queued meanwhile that falls due within that range
///   runs too. Virtual time then stands at now + d.
/// - `runUntilIdle()` runs the work due now (and what that queues for now) and does not move time on.
/// - The wall clock is `start` + virtual time + a manual offset (`wallClockOffset`, `setWallClock`): a jump of the wall
///   clock (an event script's `clock` step) does not move the monotonic clock or the queue.
///
/// Thread-safe: background work posts from any thread. The skins it runs are owned by the thread that made it
/// (`isCurrent`), which is also the thread that steps it. Stepping is not re-entrant: from inside a piece of its own
/// work `advance` and `runUntilIdle` do nothing.
public final class VirtualTimeExecutor: SkinExecutor, @unchecked Sendable {
    /// The wall clock at virtual time 0.
    public let start: Date
    /// The monotonic clock (`SkinClock.uptime`) at virtual time 0: a Mac that has been up for a day unless given.
    public let startUptime: TimeInterval
    /// How the skins' background work runs here: fakes, reports of work that has none, and the wait for real work.
    public let background: VirtualBackgroundWork

    private let owner: pthread_t
    private let lock = NSLock()
    private var elapsed: TimeInterval = 0
    private var offset: TimeInterval = 0
    private var zone: TimeZone
    private var sequence: UInt64 = 0
    private var queue = VirtualWorkQueue()
    private var stepping = false

    /// At most this many pieces of work in one `advance` / `runUntilIdle`: a skin whose work queues more work for the
    /// same moment without end (a hop that posts itself again) stops the step instead of hanging the process.
    public static let maxWorkPerStep = 1_000_000

    /// `start`: the wall clock at virtual time 0; `timeZone`: the skins' local time zone. The calling thread owns the
    /// skins that run on it.
    public init(start: Date, timeZone: TimeZone, startUptime: TimeInterval = SteppedSkinClock.defaultUptime) {
        self.start = start
        self.startUptime = startUptime
        zone = timeZone
        owner = pthread_self()
        background = VirtualBackgroundWork()
        background.executor = self
    }

    // MARK: Time

    /// Virtual seconds since `start` (the monotonic clock is `startUptime` plus this).
    public var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }

    /// The wall clock: `start` + virtual time + `wallClockOffset`.
    public var wallClock: Date {
        lock.lock()
        defer { lock.unlock() }
        return start.addingTimeInterval(elapsed + offset)
    }

    /// The monotonic clock the skins read: `startUptime` + virtual time.
    public var uptime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return startUptime + elapsed
    }

    /// Seconds the wall clock is set away from `start` + virtual time (a manual jump; 0 at first). Non-finite values
    /// are ignored.
    public var wallClockOffset: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return offset
        }
        set {
            guard newValue.isFinite else { return }
            lock.lock()
            offset = newValue
            lock.unlock()
        }
    }

    /// Sets the wall clock to `date` from now on (only the offset changes; the queue and the monotonic clock stay).
    public func setWallClock(_ date: Date) {
        lock.lock()
        let value = date.timeIntervalSince(start) - elapsed
        if value.isFinite { offset = value }
        lock.unlock()
    }

    /// The skins' local time zone.
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

    /// The clock to give the skins that run here (`Skin.runInVirtualTime` does): it reads this executor at every call.
    public var clock: SkinClock {
        SkinClock(now: { [self] in wallClock }, uptime: { [self] in uptime }, timeZone: { [self] in timeZone })
    }

    // MARK: SkinExecutor

    public var isCurrent: Bool { pthread_equal(owner, pthread_self()) != 0 }

    public func async(_ work: @escaping () -> Void) {
        schedule(after: 0, SkinScheduledWork(work), repeating: nil)
    }

    @discardableResult
    public func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
        let scheduled = SkinScheduledWork(work)
        schedule(after: delay, scheduled, repeating: nil)
        return scheduled
    }

    public func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
                      _ fire: @escaping () -> Void) -> SkinScheduledWork {
        let scheduled = SkinScheduledWork(repeats: repeats, fire)
        var i = interval.isNaN ? 0 : max(interval, 0)
        if repeats { i = max(i, VirtualTimeExecutor.minimumRepeatInterval) }
        schedule(after: i, scheduled, repeating: repeats ? i : nil)
        return scheduled
    }

    /// A repeating timer's shortest interval (Foundation's, for an interval of 0 or less).
    static let minimumRepeatInterval: TimeInterval = 0.0001

    /// `t` rounded to a whole number of nanoseconds (below a million seconds, where a nanosecond is still finer than
    /// a double can tell apart; later times, and times that are not finite, as they are). See the rules above.
    static func onGrid(_ t: TimeInterval) -> TimeInterval {
        guard t.isFinite, abs(t) < 1e6 else { return t }
        return (t * 1e9).rounded() / 1e9
    }

    private func schedule(after delay: TimeInterval, _ work: SkinScheduledWork, repeating: TimeInterval?) {
        let d = delay.isNaN ? 0 : max(delay, 0)
        lock.lock()
        sequence &+= 1
        let origin = elapsed
        queue.push(VirtualWorkItem(due: VirtualTimeExecutor.onGrid(origin + d), sequence: sequence, work: work,
                                   interval: repeating, origin: origin, tick: 1))
        lock.unlock()
    }

    // MARK: Stepping

    /// Runs the work due now, and what it queues for now, without moving time on. Returns how many pieces ran.
    @discardableResult
    public func runUntilIdle() -> Int {
        run(through: nil)
    }

    /// Moves virtual time on by `seconds` (negative or not finite: 0), running in order the work that falls due. Returns
    /// how many pieces ran.
    @discardableResult
    public func advance(by seconds: TimeInterval) -> Int {
        let d = seconds.isFinite ? max(seconds, 0) : 0
        lock.lock()
        let target = VirtualTimeExecutor.onGrid(elapsed + d)
        lock.unlock()
        return run(through: target)
    }

    /// Moves virtual time on to `time` seconds after `start` (no earlier than now), running what falls due: the same as
    /// `advance(by: time - now)`, without the rounding of that subtraction (`--render` update i is at exactly i
    /// intervals).
    @discardableResult
    public func advance(until time: TimeInterval) -> Int {
        guard time.isFinite else { return 0 }
        return run(through: VirtualTimeExecutor.onGrid(time))
    }

    /// The due time of the next piece of work still pending (nil: none).
    public var nextDue: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return queue.firstPending?.due
    }

    /// Pieces of work (and timers) still pending.
    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.pendingCount
    }

    /// Whether the last step stopped at `maxWorkPerStep`.
    public private(set) var overran = false

    private func run(through target: TimeInterval?) -> Int {
        lock.lock()
        guard !stepping else {
            lock.unlock()
            return 0
        }
        stepping = true
        let limit = target.map { max($0, elapsed) } ?? elapsed
        lock.unlock()
        var count = 0
        overran = false
        while true {
            lock.lock()
            guard let item = queue.first, item.due <= limit else {
                if target != nil, limit > elapsed { elapsed = limit }
                stepping = false
                lock.unlock()
                break
            }
            if count >= VirtualTimeExecutor.maxWorkPerStep {
                overran = true
                stepping = false
                lock.unlock()
                break
            }
            queue.popFirst()
            if item.due > elapsed { elapsed = item.due }
            lock.unlock()
            guard item.work.isPending else { continue }
            count += 1
            item.work.fire()
            // A repeating timer that is still firing: its next firing, k + 1 intervals after the time it was made.
            if let interval = item.interval, item.work.isPending {
                lock.lock()
                sequence &+= 1
                let tick = item.tick + 1
                queue.push(VirtualWorkItem(due: VirtualTimeExecutor.onGrid(item.origin + Double(tick) * interval),
                                           sequence: sequence, work: item.work, interval: interval,
                                           origin: item.origin, tick: tick))
                lock.unlock()
            }
        }
        return count
    }
}

// MARK: - Queue

struct VirtualWorkItem {
    let due: TimeInterval
    let sequence: UInt64
    let work: SkinScheduledWork
    /// A repeating timer's interval.
    let interval: TimeInterval?
    /// When the work was handed over (a repeating timer's k-th firing is due at `origin` + k × `interval`).
    let origin: TimeInterval
    /// Which firing this is (1 for the first).
    let tick: Int

    func precedes(_ other: VirtualWorkItem) -> Bool {
        due != other.due ? due < other.due : sequence < other.sequence
    }
}

/// A binary heap ordered by (due, sequence).
struct VirtualWorkQueue {
    private var items: [VirtualWorkItem] = []

    var first: VirtualWorkItem? { items.first }

    var pendingCount: Int { items.reduce(0) { $0 + ($1.work.isPending ? 1 : 0) } }

    var firstPending: VirtualWorkItem? {
        items.filter { $0.work.isPending }.min { $0.precedes($1) }
    }

    mutating func push(_ item: VirtualWorkItem) {
        items.append(item)
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].precedes(items[parent]) else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func popFirst() {
        guard !items.isEmpty else { return }
        items.swapAt(0, items.count - 1)
        items.removeLast()
        var parent = 0
        while true {
            let left = 2 * parent + 1, right = left + 1
            var first = parent
            if left < items.count, items[left].precedes(items[first]) { first = left }
            if right < items.count, items[right].precedes(items[first]) { first = right }
            guard first != parent else { break }
            items.swapAt(parent, first)
            parent = first
        }
    }
}

// MARK: - Skin

extension Skin {
    /// Runs this skin in `executor`'s virtual time: its work, its clock (wall clock, monotonic clock, time zone) and its
    /// background work (`background`) all go through the executor. Call before `load()`.
    public func runInVirtualTime(_ executor: VirtualTimeExecutor) {
        self.executor = executor
        skinClock = executor.clock
    }
}
