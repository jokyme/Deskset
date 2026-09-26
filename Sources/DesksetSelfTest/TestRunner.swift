import Foundation

/// Minimal test harness (no XCTest). Each test file exposes `func runXxxTests(_ t: TestRunner)`.
///
///     t.suite("Formula: operators") {
///         t.equal(try Formula.evaluate("1+2*3"), 7)
///     }
final class TestRunner {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentSuite = ""
    private let filter: String?
    /// How long each suite took (for the slowest ones listed by `finish()`).
    private var durations: [(name: String, seconds: TimeInterval)] = []
    private let watchdog = SuiteWatchdog(defaultLimit: 600)

    /// `swift run DesksetSelfTest formula` runs only suites whose name contains "formula" (case-insensitive).
    init(arguments: [String]) {
        filter = arguments.dropFirst().first?.lowercased()
        // Line by line, so a run that is stopped (CI's time limit, the watchdog) still shows how far it got.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    func suite(_ name: String, _ body: () throws -> Void) {
        if let filter, !name.lowercased().contains(filter) { return }
        currentSuite = name
        let before = failures.count
        let start = ProcessInfo.processInfo.systemUptime
        watchdog.start(name)
        do {
            try body()
        } catch {
            record("unexpected error thrown: \(error)", file: #fileID, line: #line)
        }
        watchdog.stop()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        durations.append((name, seconds))
        let time = seconds >= 1 ? String(format: "  (%.1f s)", seconds) : ""
        print((failures.count == before ? "  ok      \(name)" : "  FAILED  \(name)") + time)
    }

    func check(_ condition: Bool, _ message: @autoclosure () -> String = "",
               file: StaticString = #fileID, line: UInt = #line) {
        if condition { passed += 1 } else { record("check failed \(message())", file: file, line: line) }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ message: @autoclosure () -> String = "",
                             file: StaticString = #fileID, line: UInt = #line) {
        if actual == expected {
            passed += 1
        } else {
            record("expected \(String(reflecting: expected)), got \(String(reflecting: actual)) \(message())",
                   file: file, line: line)
        }
    }

    func close(_ actual: Double, _ expected: Double, accuracy: Double = 1e-9,
               _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
        if abs(actual - expected) <= accuracy || (actual.isNaN && expected.isNaN) {
            passed += 1
        } else {
            record("expected \(expected) ± \(accuracy), got \(actual) \(message())", file: file, line: line)
        }
    }

    func throwsError(_ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line,
                     _ body: () throws -> Void) {
        do {
            try body()
            record("expected an error \(message())", file: file, line: line)
        } catch {
            passed += 1
        }
    }

    // MARK: Temporary files

    /// The user's temporary directory as the process started, shared by every process of the user (the parent of
    /// `temporaryRoot` and the place of the lock file). Foundation on macOS takes it from
    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)` and ignores `TMPDIR`, so running with `TMPDIR=$(mktemp -d)` does not
    /// separate runs: DesksetCore (e.g. `.rmskin` extraction) puts its `Deskset-…` folders there all the same.
    static let sharedTemporaryDirectory = FileManager.default.temporaryDirectory

    /// This run's own folder (`DesksetSelfTest-run-…` in the system temporary directory): every `temporaryDirectory()`
    /// lives inside it, so overlapping runs never see each other's test files. Removed by `finish()`. `TMPDIR` is set
    /// to it as well, for the tools the tests start.
    let temporaryRoot: URL = {
        let root = TestRunner.sharedTemporaryDirectory
            .appendingPathComponent("DesksetSelfTest-run-\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("TMPDIR", root.path + "/", 1)
        return root
    }()

    /// A fresh empty temporary directory for file-based tests (inside `temporaryRoot`).
    func temporaryDirectory(_ label: String = "test") -> URL {
        let url = temporaryRoot.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Names in the temporary directory DesksetCore uses (`FileManager.default.temporaryDirectory`) that start with
    /// `prefix` (e.g. its `Deskset-` work folders).
    func systemTemporaryItems(prefix: String) -> Set<String> {
        let path = FileManager.default.temporaryDirectory.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return Set(names.filter { $0.hasPrefix(prefix) })
    }

    /// Items with `prefix` that appeared in the system temporary directory since `before` and are still there: the
    /// leftovers of the operation that ran in between. Other processes (a parallel `Deskset --self-test`, the app)
    /// may create and remove such folders at any moment; theirs disappear again, a leftover does not. New items are
    /// therefore re-checked for up to `grace` seconds and only those that remain are returned. Suites that use
    /// this should run inside `withSystemTemporaryDirectoryLock` so that overlapping DesksetSelfTest runs cannot
    /// interleave.
    func newSystemTemporaryItems(prefix: String, since before: Set<String>, grace: TimeInterval = 5) -> Set<String> {
        var fresh = systemTemporaryItems(prefix: prefix).subtracting(before)
        let deadline = Date().addingTimeInterval(grace)
        while !fresh.isEmpty && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            fresh.formIntersection(systemTemporaryItems(prefix: prefix))
        }
        return fresh
    }

    /// Runs `body` while holding an exclusive lock shared by all DesksetSelfTest processes of the user (a `flock` on
    /// a file in the system temporary directory), so tests that compare listings of that directory do not overlap
    /// with the same tests of another run. Waits at most `timeout` seconds for the lock; after that `body` runs
    /// anyway (with a note), so a stuck process cannot hang the suite.
    func withSystemTemporaryDirectoryLock<T>(timeout: TimeInterval = 180, _ body: () throws -> T) rethrows -> T {
        let path = TestRunner.sharedTemporaryDirectory.appendingPathComponent("DesksetSelfTest-tmp.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        var locked = false
        if fd >= 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while !locked {
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    locked = true
                    break
                }
                let busy = errno == EWOULDBLOCK || errno == EINTR
                if !busy || Date() >= deadline { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if !locked { print("  note    running without the temporary-directory lock (\(path))") }
        defer {
            if fd >= 0 {
                if locked { flock(fd, LOCK_UN) }
                _ = Darwin.close(fd)
            }
        }
        return try body()
    }

    /// Removes `temporaryRoot`, making folders the tests left read-only or unreadable writable first. Bounded.
    private func removeTemporaryRoot() {
        let fm = FileManager.default
        if (try? fm.removeItem(at: temporaryRoot)) != nil { return }
        var pending = [temporaryRoot]
        var visited = 0
        while let folder = pending.popLast(), visited < 200_000 {
            visited += 1
            var info = stat()
            guard lstat(folder.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            _ = chmod(folder.path, (info.st_mode & 0o777) | 0o700)
            for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] {
                pending.append(folder.appendingPathComponent(name))
            }
        }
        try? fm.removeItem(at: temporaryRoot)
    }

    func finish() -> Never {
        removeTemporaryRoot()
        printSlowest(durations)
        if let suite = SuiteWatchdog.overran { failures.append("[\(suite)] ran over the watchdog's limit (see HANG)") }
        print("")
        if failures.isEmpty {
            print("All \(passed) checks passed.")
            exit(0)
        }
        print("\(failures.count) FAILED, \(passed) passed:")
        for f in failures { print("  - \(f)") }
        exit(1)
    }

    private func record(_ message: String, file: StaticString, line: UInt) {
        let entry = "[\(currentSuite)] \(file):\(line): \(message)"
        failures.append(entry)
        print("    ✗ \(entry)")
    }
}
