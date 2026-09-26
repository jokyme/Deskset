import Foundation

// State that shared services keep for every skin, which skins are to read from threads of their own
// (docs/skin-threading.md §4.5, §4.6, phase 1).

/// A value behind a lock of its own: a cache group of a shared service, which skins on different threads read and
/// fill at the same time. Keep the closures short (look up, store); slow work (a system call that can take a while,
/// an IPC round trip) is better done between two accesses, so the other threads never wait for it.
final class Guarded<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func access<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// A copy of the value.
    var current: Value {
        access { $0 }
    }
}

/// A value that only the main thread can work out, because it comes from AppKit (the app's appearance, a screen's
/// desktop picture, a permission), but that skins read from their own threads.
///
/// - A read on the main thread works the value out, as every read did while all skins ran there, and publishes it.
/// - A read on any other thread gets the value last published, without waiting. When that is older than `maxAge`, or
///   nothing was published yet, it also asks the main thread to work it out again (one request at a time), so a later
///   read sees the change: a skin never waits for the main thread (§5.2).
/// - Before anything is published, other threads get `initial`.
final class MainPublished<Value> {
    private let lock = NSLock()
    private var published: (value: Value, time: TimeInterval)?
    private var requested = false
    private let initial: Value
    let maxAge: TimeInterval
    /// Works the value out (main thread). Set before the first read; objects whose value depends on themselves set it
    /// at the end of their `init`.
    var compute: () -> Value
    /// Replaced in tests.
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(maxAge: TimeInterval, initial: Value, compute: @escaping () -> Value) {
        self.maxAge = maxAge
        self.initial = initial
        self.compute = compute
    }

    /// Any thread (see the type comment).
    func value() -> Value {
        if Thread.isMainThread { return refresh() }
        let now = clock()
        lock.lock()
        let current = published
        let due = !requested && (current.map { now - $0.time >= maxAge } ?? true)
        if due { requested = true }
        lock.unlock()
        if due {
            DispatchQueue.main.async {
                // Requested by another thread: a read on the main thread may have published it meanwhile.
                self.lock.lock()
                let fresh = self.published.map { self.clock() - $0.time < self.maxAge } ?? false
                if fresh { self.requested = false }
                self.lock.unlock()
                if !fresh { self.refresh() }
            }
        }
        return current?.value ?? initial
    }

    /// Main thread: works the value out and publishes it.
    @discardableResult
    func refresh() -> Value {
        let value = compute()
        publish(value)
        return value
    }

    /// Publishes a value the main thread has (for example from a notification), for the other threads.
    func publish(_ value: Value) {
        let now = clock()
        lock.lock()
        published = (value, now)
        requested = false
        lock.unlock()
    }

    /// What another thread would read now, without asking for anything (tests).
    var lastPublished: Value? {
        lock.lock()
        defer { lock.unlock() }
        return published?.value
    }
}
