import Foundation

/// A bounded set of skin threads. A config always maps to the same worker, including across refreshes: its Lua state,
/// timers, caches and drawing never migrate while it runs. Each worker shares its update scheduler among its skins.
///
/// Workers start on demand and stay until `stop()`. Keys are not retained, so loading and unloading ever-changing
/// config names does not grow a registry. Use a normalised config name as the key. The initial two-worker policy
/// gives independent work somewhere to run while keeping low-frequency update clocks together.
public final class SkinThreadPool {
    public static let defaultWorkerCount = 2
    public let workerCount: Int
    private let lock = NSLock()
    private var workers: [SkinThreadExecutor?]

    public init(workerCount: Int = SkinThreadPool.defaultWorkerCount) {
        precondition(workerCount > 0, "A skin thread pool needs at least one worker")
        self.workerCount = workerCount
        workers = Array(repeating: nil, count: workerCount)
    }

    /// Thread-safe. Stable across processes, so a skin's placement is reproducible when diagnosing a stall.
    public func executor(for key: String) -> SkinThreadExecutor {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let index = Int(hash % UInt64(workerCount))
        lock.lock()
        defer { lock.unlock() }
        if let worker = workers[index] { return worker }
        let worker = SkinThreadExecutor(name: "Deskset skin worker \(index + 1)", qualityOfService: .userInitiated)
        workers[index] = worker
        return worker
    }

    /// Threads made so far, in worker order. The caller may keep these while waiting for a stopped pool to exit.
    public var activeWorkers: [SkinThreadExecutor] {
        lock.lock()
        defer { lock.unlock() }
        return workers.compactMap { $0 }
    }

    /// Close the skins first. Work already queued finishes; a later request starts a new worker for that slot.
    public func stop() {
        lock.lock()
        let previous = workers.compactMap { $0 }
        workers = Array(repeating: nil, count: workerCount)
        lock.unlock()
        for worker in previous { worker.stop() }
    }
}
