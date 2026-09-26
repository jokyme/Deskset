import Foundation

/// Ends a run that is stuck in one suite, so CI says where instead of running into the job's time limit with nothing
/// in the log: after `limit` seconds in one suite it names the suite, prints every thread's stack (`/usr/bin/sample`)
/// and exits with status 3. `DESKSET_SUITE_TIMEOUT` (seconds; 600 by default) sets the limit; 0 turns the watchdog
/// off.
final class SuiteWatchdog {
    let limit: TimeInterval
    private let queue = DispatchQueue(label: "app.deskset.selftest.watchdog")
    private var timer: DispatchSourceTimer?
    private static let lock = NSLock()
    private static var firedSuite: String?

    /// The suite that ran over its limit, when the watchdog fired but the suite finished while its stacks were being
    /// printed (slow rather than stuck): the run still fails.
    static var overran: String? {
        lock.lock()
        defer { lock.unlock() }
        return firedSuite
    }

    init(defaultLimit: TimeInterval) {
        limit = ProcessInfo.processInfo.environment["DESKSET_SUITE_TIMEOUT"].flatMap(Double.init) ?? defaultLimit
    }

    func start(_ suite: String) {
        stop()
        guard limit > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + limit)
        let limit = self.limit
        timer.setEventHandler { SuiteWatchdog.fire(suite, after: limit) }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Runs on the watchdog's queue while the main thread is stuck: writes straight to the file descriptors (stdout is
    /// line-buffered, so the suites' lines are already out) and leaves with `_exit`, which does not wait for locks
    /// the stuck thread may hold.
    private static func fire(_ suite: String, after limit: TimeInterval) {
        lock.lock()
        firedSuite = suite
        lock.unlock()
        let seconds = String(format: "%g", limit)
        let note = "\n  HANG    \(suite): still running after \(seconds) s; the stacks of every thread follow\n"
        FileHandle.standardOutput.write(Data(note.utf8))
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = [String(getpid()), "3", "-mayDie", "-file", "/dev/stdout"]
        sample.standardOutput = FileHandle.standardOutput
        sample.standardError = FileHandle.standardError
        if (try? sample.run()) != nil { sample.waitUntilExit() }
        FileHandle.standardOutput.write(Data("\n  HANG    \(suite): stopped the run\n".utf8))
        _exit(3)
    }
}

/// The ten slowest suites with their share of the run (where CI's time goes).
func printSlowest(_ durations: [(name: String, seconds: TimeInterval)]) {
    let total = durations.reduce(0) { $0 + $1.seconds }
    guard durations.count > 1, total >= 1 else { return }
    print("")
    print(String(format: "Slowest suites (%d suites, %.0f s in all):", durations.count, total))
    for d in durations.sorted(by: { $0.seconds > $1.seconds }).prefix(10) {
        print(String(format: "  %7.1f s  %4.1f %%  %@", d.seconds, d.seconds / total * 100, d.name))
    }
}
