import Foundation

/// A value behind a lock of its own: a cache group of a shared service, which skins on different threads read and
/// fill at the same time. Keep the closures short (look up, store); slow work (a system call that can take a while,
/// an IPC round trip) is better done between two accesses, so the other threads never wait for it.
package final class Guarded<Value> {
    private let lock = NSLock()
    private var value: Value

    package init(_ value: Value) {
        self.value = value
    }

    package func access<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// A copy of the value.
    package var current: Value {
        access { $0 }
    }
}
