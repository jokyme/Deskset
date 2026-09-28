import Foundation

// A skin executor on a thread of its own (docs/skin-threading.md §5.3): what desktop skins run on with
// `SkinThreading=engine`. In phase 2 every desktop skin shares one of them, the engine thread; phase 3 gives each skin
// one. The stress suite and the self-tests that need a skin off the main thread use it too.

/// A skin executor on a dedicated `Thread` with a run loop of its own and an 8 MB stack, like the main thread's
/// (§5.3, §7.4): the engine was written and tested against that much, and a skin thread behaves like a small main
/// thread — Foundation timers, run-loop observers (the frame producer draws at the end of each turn) and
/// `CATransaction`'s end-of-turn flush all work there.
///
/// - `async` queues a block on the thread's run loop (`CFRunLoopPerformBlock`): first in, first out, never inline, not
///   even when called on the thread.
/// - Delayed work and timers are Foundation timers on that run loop in the common modes, installed and invalidated on
///   the thread (a timer belongs to the thread whose run loop it was added to); cancelling one from another thread
///   invalidates it there, and it does nothing meanwhile.
/// - `exclusive` parks the thread between two pieces of work (`SkinExecutorPark`): while the caller holds it,
///   `isCurrent` is true on the caller's thread and false on this one. On a thread shared by several skins that parks
///   them all.
/// - `stop()` ends the thread once the work queued before it has run. Work queued later never runs: a skin's own work
///   cannot come later (the skin is closed and let go of first), and what background work hands over holds the skin
///   weakly (`SkinHop`), so nothing queued late keeps a skin.
/// - The thread is marked as a skin thread (`isSkinThread`): debug builds check that nothing there waits for the main
///   thread (§5.2).
public final class SkinThreadExecutor: SkinExecutor, @unchecked Sendable {
    /// Set up on the thread before `init` returns and read-only afterwards, except `stopped` (the thread's own).
    private final class Loop {
        var runLoop: CFRunLoop?
        var thread: pthread_t?
        var stopped = false
    }

    /// The thread's name (in crash reports, `sample` and Instruments).
    public let name: String
    private let loop = Loop()
    private let park = SkinExecutorPark()
    private let lock = NSLock()
    private var exited = false
    private var parksQueued = 0

    /// The 8 MB of the main thread's stack (§5.3).
    public static let defaultStackSize = 8 << 20

    /// Starts the thread and returns once its run loop is there. `qualityOfService`: `.userInitiated` for the skins one
    /// sees (§5.3).
    public init(name: String, stackSize: Int = SkinThreadExecutor.defaultStackSize,
                qualityOfService: QualityOfService = .userInitiated) {
        self.name = name
        let loop = self.loop
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [lock, weak self] in
            loop.runLoop = CFRunLoopGetCurrent()
            loop.thread = pthread_self()
            SkinThreadExecutor.markCurrentThread()
            // A port keeps the run loop waiting when it has no timer, rather than returning at once.
            RunLoop.current.add(NSMachPort(), forMode: .default)
            ready.signal()
            while !loop.stopped {
                autoreleasepool { _ = RunLoop.current.run(mode: .default, before: .distantFuture) }
            }
            lock.lock()
            self?.exited = true
            lock.unlock()
        }
        thread.name = name
        thread.stackSize = stackSize
        thread.qualityOfService = qualityOfService
        thread.start()
        // Waits for a new thread to start, never for skin work.
        ready.wait()
    }

    /// An executor nobody holds any more ends its thread after the work queued so far (the skins on it hold it
    /// while they live, so they have gone).
    deinit {
        let loop = self.loop
        guard let runLoop = loop.runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            loop.stopped = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    public var isCurrent: Bool { park.isCurrent(onThread: loop.thread) }

    /// The thread's run loop, where the frame producer of a skin on it draws at the end of each turn.
    public var runLoop: CFRunLoop? { loop.runLoop }

    /// The caller is the executor's own thread, whoever holds exclusive access: where its run loop is.
    public var isOnThread: Bool {
        guard let thread = loop.thread else { return false }
        return pthread_equal(thread, pthread_self()) != 0
    }

    /// The thread has ended (after `stop()`).
    public var hasExited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return exited
    }

    /// Parks queued and not started yet (tests wait for one before they let a busy thread go on).
    public var queuedParks: Int {
        lock.lock()
        defer { lock.unlock() }
        return parksQueued
    }

    public func async(_ work: @escaping () -> Void) {
        guard let runLoop = loop.runLoop else { return }
        let loop = self.loop
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            // The run loop runs every block queued before it looked, also those queued after the one that stopped it.
            guard !loop.stopped else { return }
            autoreleasepool { work() }
        }
        CFRunLoopWakeUp(runLoop)
    }

    @discardableResult
    public func async(after delay: TimeInterval, _ work: @escaping () -> Void) -> SkinScheduledWork {
        schedule(SkinScheduledWork(work), interval: delay, leeway: 0, repeats: false)
    }

    public func timer(interval: TimeInterval, leeway: TimeInterval, repeats: Bool,
                      _ fire: @escaping () -> Void) -> SkinScheduledWork {
        schedule(SkinScheduledWork(repeats: repeats, fire), interval: interval, leeway: leeway, repeats: repeats)
    }

    /// At once on the executor (re-entrant); from another thread, once the thread has parked between two pieces of
    /// work, or nil after `timeout` seconds (see `SkinExecutor.exclusive`). A skin thread asking another skin thread
    /// would wait sideways (§5.2): debug builds stop there.
    public func exclusive<T>(timeout: TimeInterval, _ body: () -> T) -> T? {
        if isCurrent { return body() }
        SkinThreadExecutor.assertNotWaiting(on: "another skin thread's exclusive access")
        return park.exclusive(timeout: timeout, enqueue: { wait in
            lock.lock()
            parksQueued += 1
            lock.unlock()
            self.async {
                self.lock.lock()
                self.parksQueued -= 1
                self.lock.unlock()
                wait()
            }
        }, body)
    }

    /// Ends the thread once the work queued before this has run. Any thread; the skins on it must have closed.
    public func stop() {
        let loop = self.loop
        async {
            loop.stopped = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    /// Installs a timer for `scheduled` on the thread: at once when called there (it still fires on a later turn,
    /// never inline), else on the thread's next turn.
    private func schedule(_ scheduled: SkinScheduledWork, interval: TimeInterval, leeway: TimeInterval,
                          repeats: Bool) -> SkinScheduledWork {
        let install = { [weak self] in
            // Cancelled before it was installed.
            guard let self, scheduled.isPending else { return }
            let timer = Timer(timeInterval: max(interval, 0), repeats: repeats) { _ in scheduled.fire() }
            timer.tolerance = leeway
            RunLoop.current.add(timer, forMode: .common)
            // Weak: the run loop owns the timer until it is invalidated (a one-shot invalidates itself once it fired).
            scheduled.setCancelHandler { [weak self, weak timer] in
                guard let self else { return }
                if self.isOnThread {
                    timer?.invalidate()
                } else {
                    // Until then, `fire()` does nothing.
                    self.async { timer?.invalidate() }
                }
            }
        }
        if isOnThread { install() } else { async(install) }
        return scheduled
    }

    // MARK: Skin threads

    private static let markerKey: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    private static func markCurrentThread() {
        pthread_setspecific(markerKey, UnsafeRawPointer(bitPattern: 1))
    }

    /// The calling thread is a skin executor's thread (any `SkinThreadExecutor`), whether or not someone holds
    /// exclusive access to it. False on the main thread, also while it holds a skin thread's skins.
    public static var isSkinThread: Bool {
        pthread_getspecific(markerKey) != nil
    }

    /// Debug builds: stops when a skin thread is about to wait for `what` (§5.2: a skin thread waits only for shared
    /// services and leaf locks — never for the main thread or another skin), or to run work that only the main
    /// thread may run, which it could only get done by waiting. Release builds compile it away.
    @inline(__always)
    public static func assertNotWaiting(on what: @autoclosure () -> String) {
        #if DEBUG
        if isSkinThread { waitViolation(what()) }
        #endif
    }

    #if DEBUG
    /// What a failed `assertNotWaiting` does: stops a debug build. Tests replace it.
    public static var waitViolation: (String) -> Void = { what in
        assertionFailure("A skin thread waits for \(what) (docs/skin-threading.md §5.2)")
    }
    #endif
}
