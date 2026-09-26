import Foundation

// The seam for running skins off the main thread (docs/skin-threading.md, phase 0). Every piece of skin work that
// runs later — the update clock, `!Delay`, plugin and meter timers, the results of background work — is scheduled
// through the skin's executor instead of the main queue or the main run loop. Today every skin uses
// `MainSkinExecutor`, which is exactly what the engine did before; later phases give each skin a thread of its own.

// MARK: - Executor

/// Where a skin's own work runs (docs/skin-threading.md §5.3): its update clock, `!Delay`, the timers of its plugins
/// and meters, and the results of the background work it started (a file read, a child process, a web request).
///
/// Everything a `Skin` owns — sections, measures, meters, Lua states, per-skin caches — is touched only by the thread
/// that owns the skin, its executor (§3, §5.2). Engine code never schedules skin work on the main queue or the main
/// run loop itself: it goes through `Skin.executor`, or through `Skin.async` / `Skin.hop()`, which also keep the skin
/// alive while the work runs (and `Skin.async` until then).
///
/// What every executor guarantees, and the engine relies on:
/// - `async` and `async(after:)` never run the work inline, not even when called on the executor: RunCommand's start
///   failure and a WebParser download with a bad URL run their actions "after the current action" that way.
/// - Work handed to `async` runs in order (first in, first out), one piece at a time, on the executor.
/// - A timer never fires inline either, not even with interval 0 (the first ActionTimer step runs after the action
///   that sent Execute). A timer that is late fires once, not in a burst.
/// - What `async(after:)` and `timer` return can be cancelled from any thread (a Foundation timer has to be
///   invalidated on the thread it was installed on: the executor takes care of that).
public protocol SkinExecutor: AnyObject {
    /// True on the executor's own thread, where the skin may be touched (`Skin.assertOwned`).
    var isCurrent: Bool { get }

    /// Runs `work` on the executor after everything handed over before it; never inline.
    func async(_ work: @escaping () -> Void)

    /// Runs `work` on the executor once `delay` seconds have passed; never inline, even for 0.
    @discardableResult
    func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork

    /// Calls `fire` on the executor after `interval` seconds and then, when `repeats`, every `interval` seconds until
    /// it is cancelled. `leeway` is how late it may fire so that the system can coalesce wake-ups (0: on time). Never
    /// fires inline, even with interval 0.
    func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
               _ fire: @escaping () -> Void) -> SkinScheduledWork
}

// MARK: - Scheduled work

/// Work an executor runs later (`SkinExecutor.async(after:)`, `SkinExecutor.timer`). It holds the closure until the
/// work has run (a one-shot) or is cancelled, and lets go of it right then: a cancelled day-long `!Delay` does not
/// keep what it captured alive until the day is over. Thread-safe.
public final class SkinScheduledWork: @unchecked Sendable {
    private enum State { case pending, fired, cancelled }

    private let lock = NSLock()
    private let repeats: Bool
    private var state = State.pending
    private var work: (() -> Void)?
    private var cancelHandler: (() -> Void)?

    /// `repeats`: a timer that runs the work every time it fires, until it is cancelled.
    public init(repeats: Bool = false, _ work: @escaping () -> Void) {
        self.repeats = repeats
        self.work = work
    }

    /// Not run yet (a one-shot) or still firing (a repeating timer), and not cancelled.
    public var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .pending
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    /// For executors: runs the work when it is due, on the executor — unless it was cancelled; a one-shot runs once.
    public func fire() {
        lock.lock()
        guard state == .pending, let work = self.work else {
            lock.unlock()
            return
        }
        var handler: (() -> Void)?
        if !repeats {
            state = .fired
            self.work = nil
            handler = cancelHandler
            cancelHandler = nil
        }
        lock.unlock()
        // Released outside the lock (as the closure is, once it has run): a deinit may schedule or cancel work.
        withExtendedLifetime(handler) {}
        work()
    }

    /// The work does not start after this; a run already under way on the executor finishes. Any thread; calling it
    /// again, or after a one-shot has run, does nothing.
    public func cancel() {
        lock.lock()
        guard state == .pending else {
            lock.unlock()
            return
        }
        state = .cancelled
        let released = work
        work = nil
        let handler = cancelHandler
        cancelHandler = nil
        lock.unlock()
        // Released outside the lock: a deinit that the release triggers may cancel other work.
        withExtendedLifetime(released) {}
        handler?()
    }

    /// For executors: what `cancel()` also has to do, such as invalidating a timer on the thread it was installed on.
    /// Runs once, on the thread that cancels (at once when the work is cancelled already); never after a one-shot
    /// has run.
    public func setCancelHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        switch state {
        case .pending:
            cancelHandler = handler
            lock.unlock()
        case .cancelled:
            lock.unlock()
            handler()
        case .fired:
            lock.unlock()
        }
    }
}

// MARK: - The main thread

/// The main queue and the main run loop: how skins have always run. Every skin uses it in this phase; later phases
/// keep it for the headless modes (`--render`, `--snapshot-ui`), the self-tests, throwaway skins and a skin open in
/// the Skin Studio (docs/skin-threading.md §5.3, §8.5).
///
/// It does exactly what the engine did before, so that nothing changes order:
/// - `async` is `DispatchQueue.main.async` and `async(after:)` is `DispatchQueue.main.asyncAfter`: the same FIFO queue
///   as the app's own "next turn" blocks (`AppController.later`) and the media centres' hops, which a run-loop
///   `perform` would overtake;
/// - timers are Foundation timers on the main run loop in the common modes, so they keep firing while a menu is open
///   or a window is dragged, with `leeway` as their tolerance;
/// - `--render` and the self-tests pump `RunLoop.main` in the default mode, which serves both.
public final class MainSkinExecutor: SkinExecutor {
    public static let shared = MainSkinExecutor()

    private init() {}

    public var isCurrent: Bool { Thread.isMainThread }

    public func async(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }

    @discardableResult
    public func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
        let scheduled = SkinScheduledWork(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { scheduled.fire() }
        return scheduled
    }

    public func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
                      _ fire: @escaping () -> Void) -> SkinScheduledWork {
        let scheduled = SkinScheduledWork(repeats: repeats, fire)
        let timer = Timer(timeInterval: interval, repeats: repeats) { _ in scheduled.fire() }
        timer.tolerance = leeway
        // Weak: the run loop owns the timer until it is invalidated (a one-shot invalidates itself once it fired).
        scheduled.setCancelHandler { [weak timer] in
            if Thread.isMainThread {
                timer?.invalidate()
            } else {
                // A timer is invalidated on the thread it was installed on; until then `fire()` does nothing.
                DispatchQueue.main.async { timer?.invalidate() }
            }
        }
        if Thread.isMainThread {
            RunLoop.main.add(timer, forMode: .common)
        } else {
            DispatchQueue.main.async { RunLoop.main.add(timer, forMode: .common) }
        }
        return scheduled
    }
}

// MARK: - The way back from background work

/// The way back to a skin's executor for background work the skin started: a file read, a child process, a network
/// request. Taken on the skin's own thread before the work starts (`Skin.hop()`); `post` may be called from any
/// thread.
///
/// It holds the skin weakly, so background work does not keep an unloaded skin alive (a 30-second ping, a scan of
/// two million files), and so does what `post` queues: the skin is looked up when the work runs, on the executor, and
/// held while it runs, so the sections the work reaches through their `unowned` `skin` stay valid
/// (docs/skin-threading.md §4.1). When the skin is gone by then, the work is dropped: the measure that asked went
/// with it.
///
/// The background thread never holds the skin, not even for a moment: if it did, it could end up holding the last
/// reference once the executor has let go, and the skin, its measures and meters would be released there — off the
/// executor, where an InputText prompt would close its window and FrostedGlass release its backdrop window.
public struct SkinHop: @unchecked Sendable {
    private weak var skin: Skin?
    private let executor: SkinExecutor

    init(skin: Skin, executor: SkinExecutor) {
        self.skin = skin
        self.executor = executor
    }

    /// Runs `work` on the skin's executor, after the work already queued there, if the skin is still there by then;
    /// otherwise `dropped` runs there instead. `dropped` is for what must not be left behind when nobody takes the
    /// result, such as a temporary file the background work saved; it must not touch the skin.
    public func post(_ work: @escaping () -> Void, orElse dropped: (() -> Void)? = nil) {
        let hop = self
        executor.async {
            guard let skin = hop.skin else {
                dropped?()
                return
            }
            withExtendedLifetime(skin) { work() }
        }
    }
}

// MARK: - Skin

extension Skin {
    /// Runs `work` on the skin's executor after the current work — "after the current action" — never inline. The
    /// queued work keeps the skin alive until it has run. Only the executor calls this, so the skin is let go of there
    /// either way (background work uses `hop()`, which holds it only while the work runs).
    ///
    /// Delayed work and timers (`executor.async(after:)`, `executor.timer`) do not keep the skin alive: they capture
    /// what they need weakly and are cancelled when the skin closes (`close()`, `PluginLifecycle.skinWillClose()`), so
    /// that neither a day-long `!Delay` nor the animation of a skin that is dropped without being closed (the Manage
    /// window's dry runs, component thumbnails) keeps a skin alive.
    public func async(_ work: @escaping () -> Void) {
        executor.async { withExtendedLifetime(self) { work() } }
    }

    /// The way back to this skin's executor for background work (see `SkinHop`). Take it on the skin's own thread,
    /// before the background work starts.
    public func hop() -> SkinHop {
        SkinHop(skin: self, executor: executor)
    }

    /// Debug builds: checks that the caller runs where the skin is owned, on its executor (docs/skin-threading.md
    /// §5.2). The engine's entry points call it: load, update, actions and bangs, the mouse, option reads, previews,
    /// close. Release builds compile it away.
    @inline(__always)
    func assertOwned(_ entry: StaticString = #function) {
        #if DEBUG
        if !executor.isCurrent { Skin.ownershipViolation(self, entry) }
        #endif
    }

    #if DEBUG
    /// What a failed `assertOwned` does: stops a debug build with the entry point and the config. Tests replace it.
    static var ownershipViolation: (Skin, StaticString) -> Void = { skin, entry in
        assertionFailure("Skin \(skin.config): \(entry) called off the skin's executor (docs/skin-threading.md §5.2)")
    }
    #endif
}
