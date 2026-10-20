import Foundation
import Darwin

enum StartupCrashWatcherSelfTests {
    private typealias Watcher = StartupCrashWatcher

    static func run(_ t: AppTestRunner) {
        statusTests(t)
        historyTests(t)
        reconciliationTests(t)
        startupTests(t)
        helperTests(t)
        fileTests(t)
    }

    private static func statusTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start watcher: only fatal signal exits count") {
            for signal in [SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
                t.check(Watcher.isFatalStatus(signal))
                t.check(Watcher.isFatalStatus(signal | 0x80), "the core-dump bit does not change the signal")
            }
            for status: Int32 in [0, 1 << 8, 7 << 8, 134 << 8, SIGTERM, SIGKILL, SIGINT, 0x7f, -1, 0x10006] {
                t.check(!Watcher.isFatalStatus(status), "normal exits and unclassified interruptions are not crashes")
            }
            t.equal(Watcher.runEarlyIfRequested(["Deskset", Watcher.argument]), 2)
            t.equal(Watcher.runEarlyIfRequested(["Deskset", Watcher.argument, "/tmp/x", "nonce", "extra"]), 2)
            t.equal(Watcher.runEarlyIfRequested(["Deskset", "--help"]), nil)
        }
    }

    private static func historyTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start watcher: the rolling window excludes future and expired results") {
            let rig = try Rig(t)
            for (index, signal) in [SIGABRT, SIGTRAP, SIGSEGV, SIGBUS, SIGILL, SIGFPE].enumerated() {
                _ = try rig.history(pid: pid_t(100 + index), status: signal, age: 10)
            }
            _ = try rig.history(pid: 110, status: SIGABRT, age: 300)
            _ = try rig.history(pid: 111, status: SIGABRT, age: 0)
            let expired = try rig.history(pid: 112, status: SIGABRT, age: 301)
            _ = try rig.history(pid: 113, status: SIGABRT, age: -1)
            _ = try rig.history(pid: 114, status: SIGTERM, age: 1)
            _ = try rig.history(pid: 115, status: 7 << 8, age: 1)
            _ = try rig.history(pid: 116, status: SIGKILL, age: 1)
            let active = try rig.history(pid: 117, status: SIGABRT, age: 301)
            rig.identities[117] = active.manifest.parentIdentity
            let answer = finish(t, rig.watcher())
            t.equal(answer?.recentCrashCount, 8)
            t.equal(answer?.warning, nil)
            t.check(!FileManager.default.fileExists(atPath: expired.url.path), "only completed expired history is removed")
            t.check(FileManager.default.fileExists(atPath: active.url.path), "an active identity is never removed")
        }
        t.suite("App: Safe Start watcher: one process is counted once and bad records cannot supply evidence") {
            let rig = try Rig(t)
            _ = try rig.history(pid: 101, status: SIGABRT, age: 2)
            _ = try rig.history(pid: 101, status: SIGSEGV, age: 1)
            let wrong = try rig.history(pid: 102, status: SIGABRT, age: 1)
            let other = try rig.history(pid: 103, status: SIGTERM, age: 1)
            try rig.write(Watcher.Result(ready: other.ready, exitedAt: rig.now - 1, status: SIGABRT),
                          wrong.url.appendingPathComponent("result.json"))
            let corrupt = try rig.history(pid: 104, status: SIGABRT, age: 1)
            try rig.files.write(Data("{broken".utf8), corrupt.url.appendingPathComponent("result.json"))
            let answer = finish(t, rig.watcher())
            t.equal(answer?.recentCrashCount, 1)
            t.check(answer?.warning != nil)
        }
    }

    private static func reconciliationTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start watcher: reconciliation uses one final five-minute window") {
            let rig = try Rig(t)
            _ = try rig.history(pid: 101, status: SIGABRT, age: 299.99)
            let pending = try rig.history(pid: 102, status: nil, age: 0)
            rig.identities[pending.ready.watcherPID] = pending.ready.watcherIdentity
            var dependencies = rig.dependencies()
            dependencies.now = { rig.now + rig.elapsed }
            var written = false
            rig.onPause = {
                guard !written else { return }
                written = true
                try rig.write(Watcher.Result(ready: pending.ready, exitedAt: rig.now + rig.elapsed, status: SIGSEGV),
                              pending.url.appendingPathComponent("result.json"))
            }
            let answer = finish(t, rig.watcher(dependencies))
            t.equal(answer?.recentCrashCount, 1, "a crash that expires during reconciliation cannot trigger recovery")
            t.equal(answer?.warning, nil)
            t.check(written && rig.elapsed >= 0.025)
        }
        t.suite("App: Safe Start watcher: a late result completes two rapid crashes before startup resumes") {
            let rig = try Rig(t)
            _ = try rig.history(pid: 101, status: SIGABRT, age: 2)
            let pending = try rig.history(pid: 102, status: nil, age: 1)
            rig.identities[pending.ready.watcherPID] = pending.ready.watcherIdentity
            var written = false
            rig.onPause = {
                guard !written else { return }
                written = true
                try rig.write(Watcher.Result(ready: pending.ready, exitedAt: rig.now - 1, status: SIGSEGV),
                              pending.url.appendingPathComponent("result.json"))
            }
            let answer = finish(t, rig.watcher())
            t.equal(answer?.recentCrashCount, 2)
            t.equal(answer?.warning, nil)
            t.check(written)
            t.check(rig.elapsed > 0 && rig.elapsed < 2)
        }
        t.suite("App: Safe Start watcher: missing and unfinished results are never inferred to be fatal") {
            let rig = try Rig(t)
            let live = try rig.history(pid: 101, status: nil, age: 1)
            rig.identities[live.ready.watcherPID] = live.ready.watcherIdentity
            let dead = try rig.history(pid: 102, status: nil, age: 1)
            let unready = try rig.history(pid: 103, status: nil, age: 1, ready: false)
            let answer = finish(t, rig.watcher())
            t.equal(answer?.recentCrashCount, 0)
            t.check(answer?.warning != nil)
            t.check(rig.elapsed >= 2 && rig.elapsed < 2.1, "all pending sessions share a bounded wait")
            for record in [live, dead, unready] {
                t.check(FileManager.default.fileExists(atPath: record.url.path))
            }
            // A result arriving after this startup's deadline remains valid evidence at the next startup.
            try rig.write(Watcher.Result(ready: live.ready, exitedAt: rig.now - 1, status: SIGBUS),
                          live.url.appendingPathComponent("result.json"))
            let next = finish(t, rig.watcher())
            t.equal(next?.recentCrashCount, 1)
        }
        t.suite("App: Safe Start watcher: a result committed just before its observer exits is still counted") {
            let rig = try Rig(t)
            let pending = try rig.history(pid: 101, status: nil, age: 1)
            var dependencies = rig.dependencies()
            var written = false
            dependencies.identity = { pid in
                if pid == pending.ready.watcherPID {
                    if !written {
                        written = true
                        try rig.write(Watcher.Result(ready: pending.ready, exitedAt: rig.now - 1, status: SIGABRT),
                                      pending.url.appendingPathComponent("result.json"))
                    }
                    return nil
                }
                return rig.identities[pid]
            }
            let answer = finish(t, rig.watcher(dependencies))
            t.equal(answer?.recentCrashCount, 1)
            t.equal(answer?.warning, nil)
            t.check(written)
            t.equal(rig.elapsed, 0)
        }
    }

    private static func startupTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start watcher: failed observation preserves existing crash evidence") {
            for failReady in [false, true] {
                let rig = try Rig(t)
                _ = try rig.history(pid: 101, status: SIGABRT, age: 1)
                var dependencies = rig.dependencies()
                if failReady {
                    dependencies.launch = { _, _, _ in Watcher.Child(isRunning: { true }) }
                } else {
                    dependencies.launch = { _, _, _ in throw Watcher.Failure.unavailable }
                }
                let answer = finish(t, rig.watcher(dependencies))
                t.equal(answer?.recentCrashCount, 1)
                t.check(answer?.warning != nil)
                if failReady { t.check(rig.elapsed >= 5 && rig.elapsed < 5.1) }
            }
        }
        t.suite("App: Safe Start watcher: subscribers share one child and always finish once on main") {
            let rig = try Rig(t)
            let watcher = rig.watcher()
            var callbacks = 0
            var allMain = true
            let callback: (Watcher.Summary) -> Void = { answer in
                callbacks += 1
                allMain = allMain && Thread.isMainThread
                t.equal(answer.recentCrashCount, 0)
                t.equal(answer.warning, nil)
            }
            watcher.begin(completion: callback)
            watcher.begin(completion: callback)
            t.equal(callbacks, 0, "completion never runs inline")
            t.check(AppSelfTest.spin(timeout: 5) { callbacks == 2 })
            watcher.begin(completion: callback)
            t.equal(callbacks, 2)
            t.check(AppSelfTest.spin(timeout: 5) { callbacks == 3 })
            t.check(allMain)
            t.equal(rig.launches, 1)
        }
        t.suite("App: Safe Start watcher: identity and nonce mismatches cannot complete READY") {
            for mismatch in ["nonce", "identity", "owner"] {
                let rig = try Rig(t)
                var dependencies = rig.dependencies()
                if mismatch == "identity" {
                    dependencies.identity = { pid in pid == Rig.watcherPID ? Rig.identity(999) : rig.identities[pid] }
                } else if mismatch == "owner" {
                    dependencies.owner = { pid in pid == Rig.watcherPID ? getuid() &+ 1 : getuid() }
                } else {
                    dependencies.launch = { _, manifestURL, _ in
                        let manifest = try rig.read(Watcher.Manifest.self, manifestURL)
                        let altered = Watcher.Manifest(session: manifest.session, nonce: UUID().uuidString,
                            parentPID: manifest.parentPID, parentIdentity: manifest.parentIdentity,
                            executable: manifest.executable, startedAt: manifest.startedAt)
                        try rig.write(Watcher.Ready(manifest: altered, watcherPID: Rig.watcherPID,
                                                    watcherIdentity: Rig.identity(Rig.watcherPID)),
                                      manifestURL.deletingLastPathComponent().appendingPathComponent("ready.json"))
                        return Watcher.Child(isRunning: { true })
                    }
                }
                let answer = finish(t, rig.watcher(dependencies))
                t.equal(answer?.recentCrashCount, 0)
                t.check(answer?.warning != nil)
            }
        }
    }

    private static func helperTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start watcher: registration and a second identity check precede READY") {
            let rig = try Rig(t)
            let job = try rig.helperJob()
            var events: [String] = []
            var dependencies = rig.helperDependencies()
            dependencies.identity = { pid in events.append("identity:\(pid)"); return rig.identities[pid] }
            dependencies.observe = { _ in
                events.append("register")
                return Watcher.Observation(wait: { events.append("wait"); return SIGABRT },
                                           release: { events.append("release") })
            }
            dependencies.files.write = { data, url in
                events.append(url.lastPathComponent)
                try rig.files.write(data, url)
            }
            t.equal(Watcher.runHelper(manifestURL: job.url, nonce: job.manifest.nonce, dependencies: dependencies), 0)
            guard let register = events.firstIndex(of: "register"), let ready = events.firstIndex(of: "ready.json"),
                  let wait = events.firstIndex(of: "wait"), let result = events.firstIndex(of: "result.json"),
                  let release = events.firstIndex(of: "release") else { return t.check(false, "all observation stages ran") }
            t.check(register < ready && ready < wait && wait < result && result < release)
            t.check(events[(register + 1)..<ready].contains("identity:\(Rig.parentPID)"))
            let recorded = try rig.read(Watcher.Result.self, job.url.deletingLastPathComponent().appendingPathComponent("result.json"))
            t.equal(recorded.status, SIGABRT)
            t.equal(recorded.ready.manifest, job.manifest)
        }
        t.suite("App: Safe Start watcher: replaced parent, wrong nonce and wrong owner never publish READY") {
            for mismatch in ["birth", "nonce", "owner", "executable", "registration"] {
                let rig = try Rig(t)
                let job = try rig.helperJob()
                var dependencies = rig.helperDependencies()
                var registered = 0
                var waited = 0
                dependencies.observe = { _ in
                    registered += 1
                    if mismatch == "registration" { throw Watcher.Failure.unavailable }
                    if mismatch == "birth" { rig.identities[Rig.parentPID] = Rig.identity(999) }
                    return Watcher.Observation(wait: { waited += 1; return SIGABRT })
                }
                if mismatch == "owner" { dependencies.owner = { _ in getuid() &+ 1 } }
                if mismatch == "executable" { dependencies.executable = { URL(fileURLWithPath: "/different/Deskset") } }
                let nonce = mismatch == "nonce" ? UUID().uuidString : job.manifest.nonce
                t.equal(Watcher.runHelper(manifestURL: job.url, nonce: nonce, dependencies: dependencies), 1)
                t.equal(waited, 0)
                t.equal(registered, ["birth", "registration"].contains(mismatch) ? 1 : 0)
                t.check(!FileManager.default.fileExists(atPath: job.url.deletingLastPathComponent().appendingPathComponent("ready.json").path))
            }
        }
        t.suite("App: Safe Start watcher: file failures cannot produce a partial result or observe before READY") {
            for failedFile in ["ready.json", "result.json"] {
                let rig = try Rig(t)
                let job = try rig.helperJob()
                var dependencies = rig.helperDependencies()
                var waited = false
                var released = false
                dependencies.observe = { _ in Watcher.Observation(wait: { waited = true; return 7 << 8 },
                                                                   release: { released = true }) }
                dependencies.files.write = { data, url in
                    if url.lastPathComponent == failedFile { throw CocoaError(.fileWriteNoPermission) }
                    try rig.files.write(data, url)
                }
                t.equal(Watcher.runHelper(manifestURL: job.url, nonce: job.manifest.nonce, dependencies: dependencies), 1)
                t.equal(waited, failedFile == "result.json")
                t.check(released)
                t.check(!FileManager.default.fileExists(atPath: job.url.deletingLastPathComponent().appendingPathComponent("result.json").path))
            }
        }
    }

    private static func fileTests(_ t: AppTestRunner) {
        t.suite("App: Safe Start watcher: private records reject symlinks and nonprivate files") {
            let rig = try Rig(t)
            let job = try rig.helperJob()
            let directory = job.url.deletingLastPathComponent()
            let record = directory.appendingPathComponent("test.json")
            try rig.files.write(Data("original".utf8), record)
            t.equal(try rig.files.read(record), Data("original".utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: record.path)
            do { _ = try rig.files.read(record); t.check(false, "nonprivate records are rejected") }
            catch { t.check(true) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
            let link = directory.appendingPathComponent("linked.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: record)
            do { _ = try rig.files.read(link); t.check(false, "record reads never follow a symlink") }
            catch { t.check(true) }
            try rig.files.write(Data("replacement".utf8), link)
            t.equal(try rig.files.read(record), Data("original".utf8), "an atomic replacement cannot write through a symlink")
            t.equal(try rig.files.read(link), Data("replacement".utf8))
            let linkedDirectory = rig.root.appendingPathComponent("linked-directory")
            try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
            do { _ = try rig.files.read(linkedDirectory.appendingPathComponent("test.json")); t.check(false) }
            catch { t.check(true) }
        }
    }

    private static func finish(_ t: AppTestRunner, _ watcher: Watcher) -> Watcher.Summary? {
        var answer: Watcher.Summary?
        watcher.begin { answer = $0 }
        t.check(AppSelfTest.spin(timeout: 5) { answer != nil }, "the startup check completes without blocking main")
        return answer
    }

    /// Each rig owns private files and fake processes. No real child or user application is signalled.
    private final class Rig {
        static let parentPID: pid_t = 41
        static let watcherPID: pid_t = 42
        let root: URL
        let directory: URL
        let executable = URL(fileURLWithPath: "/private/Deskset-test")
        let files = Watcher.Files()
        let now: TimeInterval = 1_000
        var elapsed: TimeInterval = 0
        var launches = 0
        var identities: [pid_t: AppUpdateInstaller.ProcessIdentity] = [parentPID: identity(parentPID), watcherPID: identity(watcherPID)]
        var onPause: (() throws -> Void)?

        struct History {
            let url: URL
            let manifest: Watcher.Manifest
            let ready: Watcher.Ready
        }

        init(_ t: AppTestRunner) throws {
            root = t.temporaryDirectory("startup-watcher").resolvingSymlinksInPath()
            directory = root.appendingPathComponent(Watcher.directoryName)
            try files.makeDirectory(directory)
        }

        static func identity(_ pid: pid_t) -> AppUpdateInstaller.ProcessIdentity {
            AppUpdateInstaller.ProcessIdentity(seconds: Int64(pid), microseconds: 123)
        }

        func write<T: Encodable>(_ value: T, _ url: URL) throws { try files.write(JSONEncoder().encode(value), url) }
        func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
            guard let data = try files.read(url) else { throw Watcher.Failure.invalidRecord }
            return try JSONDecoder().decode(type, from: data)
        }

        func history(pid: pid_t, status: Int32?, age: TimeInterval, ready writeReady: Bool = true) throws -> History {
            let manifest = Watcher.Manifest(session: UUID().uuidString, nonce: UUID().uuidString, parentPID: pid,
                parentIdentity: Self.identity(pid), executable: executable, startedAt: now - 600)
            let url = directory.appendingPathComponent(manifest.session)
            try files.makeDirectory(url)
            try write(manifest, url.appendingPathComponent("manifest.json"))
            let ready = Watcher.Ready(manifest: manifest, watcherPID: pid + 1_000, watcherIdentity: Self.identity(pid + 1_000))
            if writeReady { try write(ready, url.appendingPathComponent("ready.json")) }
            if let status { try write(Watcher.Result(ready: ready, exitedAt: now - age, status: status), url.appendingPathComponent("result.json")) }
            return History(url: url, manifest: manifest, ready: ready)
        }

        func helperJob() throws -> (url: URL, manifest: Watcher.Manifest) {
            let record = try history(pid: Self.parentPID, status: nil, age: 0, ready: false)
            return (record.url.appendingPathComponent("manifest.json"), record.manifest)
        }

        func dependencies() -> Watcher.Dependencies {
            var result = Watcher.Dependencies()
            result.identity = { self.identities[$0] }
            result.owner = { self.identities[$0] == nil ? nil : getuid() }
            result.pid = { Self.parentPID }
            result.now = { self.now }
            result.uptime = { self.elapsed }
            result.pause = { delay in self.elapsed += delay; try? self.onPause?() }
            result.executable = { self.executable }
            result.files = files
            result.launch = { _, manifestURL, _ in
                self.launches += 1
                let manifest = try self.read(Watcher.Manifest.self, manifestURL)
                try self.write(Watcher.Ready(manifest: manifest, watcherPID: Self.watcherPID,
                                             watcherIdentity: Self.identity(Self.watcherPID)),
                               manifestURL.deletingLastPathComponent().appendingPathComponent("ready.json"))
                return Watcher.Child(isRunning: { true })
            }
            return result
        }

        func helperDependencies() -> Watcher.Dependencies {
            var result = dependencies()
            result.pid = { Self.watcherPID }
            result.parentPID = { Self.parentPID }
            return result
        }

        func watcher(_ dependencies: Watcher.Dependencies? = nil) -> Watcher {
            Watcher(settingsDirectory: root, executableURL: executable, dependencies: dependencies ?? self.dependencies())
        }
    }
}
