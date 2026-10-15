import Darwin
import DesksetCore
import Foundation

/// Controlled process completions, local child scripts, and raw dictionaries. No suite starts system_profiler or
/// reads battery IOKit properties; SystemMonitor's existing CPU initialization remains unchanged.
enum BatteryDetailsServiceSelfTests {
    private typealias Service = BatteryDetailsService

    private final class Reader {
        private struct Call {
            let complete: (Service.ProfileResult) -> Void
            var finished = false
            var cancellations = 0
        }
        private struct State {
            var calls: [Call] = []
            var active = 0
            var maximumActive = 0
            var cleanups = 0
        }
        private let state = Guarded(State())
        var immediate: Service.ProfileResult?
        var beforeReturning: ((Int) -> Void)?

        var count: Int { state.access { $0.calls.count } }
        var maximumActive: Int { state.access { $0.maximumActive } }
        var cleanups: Int { state.access { $0.cleanups } }
        func cancellations(_ index: Int) -> Int { state.access { $0.calls[index].cancellations } }

        func start(_ complete: @escaping (Service.ProfileResult) -> Void) -> Service.Ticket {
            let index = state.access { s -> Int in
                let index = s.calls.count
                s.calls.append(Call(complete: complete))
                s.active += 1
                s.maximumActive = max(s.maximumActive, s.active)
                return index
            }
            if let immediate { finish(index, immediate) }
            beforeReturning?(index)
            return Service.Ticket { [self] in
                state.access { $0.calls[index].cancellations += 1 }
            }
        }

        /// Cleanup happens before delivering the result. Calling twice models a badly behaved late duplicate.
        func finish(_ index: Int, _ result: Service.ProfileResult) {
            let callback = state.access { s -> (Service.ProfileResult) -> Void in
                if !s.calls[index].finished {
                    s.calls[index].finished = true
                    s.active -= 1
                    s.cleanups += 1
                }
                return s.calls[index].complete
            }
            callback(result)
        }
    }

    private final class MainQueue {
        private let work = Guarded<[() -> Void]>([])
        var count: Int { work.access { $0.count } }
        func enqueue(_ callback: @escaping () -> Void) { work.access { $0.append(callback) } }
        func drain() {
            let callbacks = work.access { value -> [() -> Void] in
                defer { value = [] }
                return value
            }
            for callback in callbacks { callback() }
        }
    }

    private final class Fixture {
        let clock = Guarded<TimeInterval>(1_000)
        let queue = DispatchQueue(label: "app.deskset.battery-details-test")
        let reader = Reader()
        let main = MainQueue()
        let raw = Guarded<[String: Any]?>(nil)
        let rawReads = Guarded(0)
        let rawWasOnMain = Guarded<[Bool]>([])
        let changes = Guarded<[BatteryDetailsReading]>([])
        lazy var service: Service = Service(clock: { [clock = clock] in clock.current },
                                   start: { [reader = reader] in reader.start($0) },
                                   readRawBattery: { [raw = raw, rawReads = rawReads, rawWasOnMain = rawWasOnMain] in
                                       rawReads.access { $0 += 1 }
                                       rawWasOnMain.access { $0.append(Thread.isMainThread) }
                                       return raw.current
                                   }, queue: queue, scheduleMain: { [main = main] in main.enqueue($0) },
                                   didChange: { [weak self] in
                                       guard let self else { return }
                                       self.changes.access { $0.append(self.service.reading()) }
                                   })

        func flush() {
            // An inline result is queued behind drive(); a cancelled result can in turn start the next bucket.
            for _ in 0..<4 { queue.sync {} }
        }
        func finish(_ result: Service.ProfileResult) { finish(0, result) }
        func finish(_ index: Int, _ result: Service.ProfileResult) { reader.finish(index, result); flush() }
        func close() { service.stop(); flush() }
    }

    private static let raw90: [String: Any] = ["DesignCapacity": 6_000, "AppleRawMaxCapacity": 5_400,
                                              "MaxCapacity": 100, "CycleCount": 999]

    private static func profile(health: String? = "94%", cycles: Any? = 231) throws -> Data {
        var info: [String: Any] = [:]
        if let health { info["sppower_battery_health_maximum_capacity"] = health }
        if let cycles { info["sppower_battery_cycle_count"] = cycles }
        return try JSONSerialization.data(withJSONObject: ["SPPowerDataType": [["sppower_battery_health_info": info]]])
    }

    private final class Child {
        let results = Guarded<[Service.ProfileResult]>([])
        let mainCallbacks = Guarded<[Bool]>([])
        let done = DispatchSemaphore(value: 0)
        let ticket: Service.Ticket

        init(executable: String = "/bin/sh", arguments: [String], timeout: TimeInterval = 5) {
            let results = self.results, mainCallbacks = self.mainCallbacks, done = self.done
            ticket = BatteryProfileProcess.start(executable: executable, arguments: arguments, timeout: timeout) {
                result in
                mainCallbacks.access { $0.append(Thread.isMainThread) }
                results.access { $0.append(result) }
                done.signal()
            }
        }

        func finish(_ t: AppTestRunner, line: UInt = #line) -> Service.ProfileResult? {
            let completed = done.wait(timeout: .now() + 8) == .success
            t.check(completed, "the fixed child finishes off Main", line: line)
            guard completed else { ticket.cancel(); return nil }
            ticket.cancel()
            ticket.cancel()
            t.check(done.wait(timeout: .now() + 0.1) == .timedOut, "completion is delivered only once", line: line)
            t.equal(results.current.count, 1, line: line)
            t.equal(mainCallbacks.current, [false], line: line)
            return results.current.first
        }
    }

    private static func waitFor(_ condition: () -> Bool) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < end else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    private static func processIDs(_ path: URL) -> (leader: pid_t, child: pid_t)? {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let numbers = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        guard numbers.count == 2, numbers[0] > 0, numbers[1] > 0 else { return nil }
        return (numbers[0], numbers[1])
    }

    private static func checkReapedGroup(_ t: AppTestRunner, pids: (leader: pid_t, child: pid_t), line: UInt = #line) {
        var status: Int32 = 0
        let result = waitpid(pids.leader, &status, WNOHANG)
        let error = errno
        t.equal(result, -1, "the reader has already reaped its own child", line: line)
        t.equal(error, ECHILD, line: line)
        t.check(waitFor { kill(-pids.leader, 0) == -1 && errno == ESRCH },
                "the owned process group, including its background child, is gone", line: line)
        let childResult = kill(pids.child, 0)
        let childError = errno
        t.equal(childResult, -1, line: line)
        t.equal(childError, ESRCH, "the descendant did not survive the reader's completion", line: line)
    }

    static func run(_ t: AppTestRunner) {
        t.suite("App: battery details provider: profile fields win over raw health and missing cycles stay missing") {
            let valid = try profile()
            t.equal(Service.profileDetails(valid), BatteryDetails(health: 94, cycles: 231))
            t.equal(Service.profileDetails(try profile(health: " 0% ", cycles: 0)), BatteryDetails(health: 0, cycles: 0))
            for bad in ["", "94", "-1%", "101%", "NaN%", "Infinity%", "94%%"] {
                t.equal(Service.profileDetails(try profile(health: bad, cycles: 0)), BatteryDetails(cycles: 0), bad)
            }
            for bad in ([-1, true, "231", NSNull()] as [Any]) {
                t.equal(Service.profileDetails(try profile(cycles: bad)), BatteryDetails(health: 94))
            }
            t.equal(Service.profileDetails(try profile(health: nil, cycles: 0.5)), BatteryDetails(cycles: 0.5),
                    "the numeric provider contract does not invent an integer-only restriction")
            for invalid in [Data(), Data("not JSON".utf8), Data("{}".utf8),
                            Data(#"{"SPPowerDataType":[]}"#.utf8),
                            Data(#"{"SPPowerDataType":[{"sppower_battery_health_maximum_capacity":"94%","sppower_battery_cycle_count":231}]}"#.utf8)] {
                t.equal(Service.profileDetails(invalid), BatteryDetails(), "only the exact battery dictionary is read")
            }
            var atLimit = valid
            atLimit.append(Data(repeating: 32, count: Service.maximumOutputBytes - valid.count))
            t.equal(Service.profileDetails(atLimit), BatteryDetails(health: 94, cycles: 231), "a complete output at the limit is valid")
            atLimit.append(32)
            t.equal(Service.profileDetails(atLimit), BatteryDetails(), "an extra byte is rejected, not silently truncated")

            let cases: [(Data, BatteryDetails, Int)] = [
                (valid, BatteryDetails(health: 94, cycles: 231), 0),
                (try profile(health: nil), BatteryDetails(health: 90, cycles: 231), 1),
                (try profile(cycles: nil), BatteryDetails(health: 94), 0),
                (try profile(health: nil, cycles: nil), BatteryDetails(health: 90), 1)
            ]
            for (data, expected, rawCount) in cases {
                let f = Fixture()
                defer { f.close() }
                f.raw.access { $0 = raw90 }
                f.reader.immediate = .exited(status: 0, output: data)
                t.equal(f.service.reading(), .pending)
                f.flush()
                t.equal(f.service.reading(), .ready(expected))
                t.equal(f.rawReads.current, rawCount)
                t.equal(f.rawWasOnMain.current, Array(repeating: false, count: rawCount))
                t.equal(f.reader.cleanups, 1, "the reader has closed before ready is published")
                t.equal(f.changes.current, [], "publication does not call Main inline")
                f.main.drain()
                t.equal(f.changes.current, [.ready(expected)], "the observer reads the already committed snapshot")
            }
            t.equal(Service.rawHealth(raw90), 90)
            t.equal(Service.rawHealth(["DesignCapacity": 4_000, "MaxCapacity": 3_000]), 75, "Intel capacity fallback")
            for invalid in ([[:], ["DesignCapacity": 6_000, "MaxCapacity": 100],
                                           ["DesignCapacity": 0, "AppleRawMaxCapacity": 5_400],
                                           ["DesignCapacity": true, "AppleRawMaxCapacity": 1],
                                           ["DesignCapacity": 6_000, "AppleRawMaxCapacity": Double.infinity],
                                           ["DesignCapacity": 6_000, "AppleRawMaxCapacity": 6_001]] as [[String: Any]]) {
                t.equal(Service.rawHealth(invalid), nil)
            }
            t.equal(SensorReadings.battery(raw90).values["battery.health"], 90, "legacy MacSensors still uses the raw formula")
            t.equal(SensorReadings.battery(raw90).values["battery.cycles"], 999, "legacy cycle decoding remains independent")
            t.close(SensorReadings.battery(["DesignCapacity": 6_000, "AppleRawMaxCapacity": 6_060]).values["battery.health"] ?? -1,
                    101, "the new Desk range guard does not clamp legacy MacSensors")
        }

        t.suite("App: battery details provider: concurrent reads share one job and Unix buckets wait for cancellation cleanup") {
            let f = Fixture()
            defer { f.close() }
            let service = f.service
            f.clock.access { $0 = 3_599.5 }
            let readings = Guarded<[BatteryDetailsReading]>([])
            t.check(ServiceThreadingSelfTests.onThreads(8) { _ in
                for _ in 0..<20 {
                    let value = service.reading()
                    readings.access { $0.append(value) }
                }
            }, "all callers return while the fake reader remains unfinished")
            f.flush()
            t.equal(readings.current, Array(repeating: .pending, count: 160))
            t.equal(f.reader.count, 1)
            t.equal(f.reader.maximumActive, 1)
            f.finish(.exited(status: 0, output: try profile()))
            t.equal(service.reading(), .ready(BatteryDetails(health: 94, cycles: 231)))
            f.clock.access { $0 = 3_599.999 }
            t.equal(service.reading(), .ready(BatteryDetails(health: 94, cycles: 231)))
            t.equal(f.reader.count, 1)

            f.clock.access { $0 = 3_600 }
            t.equal(service.reading(), .pending)
            f.flush()
            t.equal(f.reader.count, 2, "the Unix-hour boundary starts one refresh")
            f.main.drain()
            t.equal(f.changes.current, [], "the previous bucket's delayed Main callback is discarded")
            f.clock.access { $0 = 7_200 }
            t.equal(service.reading(), .pending)
            f.flush()
            t.equal(f.reader.cancellations(1), 1)
            t.equal(f.reader.count, 2, "cancel is not cleanup: no second child may start yet")
            t.equal(f.reader.cleanups, 1)
            f.finish(1, .exited(status: 0, output: try profile(health: "12%", cycles: 1)))
            t.equal(f.reader.count, 3)
            t.equal(f.reader.cleanups, 2)
            t.equal(f.reader.maximumActive, 1)
            t.equal(service.reading(), .pending, "the old successful result cannot fill the new bucket")
            t.equal(f.main.count, 0)
            f.finish(2, .exited(status: 0, output: try profile(health: "95%", cycles: 232)))
            t.equal(service.reading(), .ready(BatteryDetails(health: 95, cycles: 232)))
            f.main.drain()
            t.equal(f.changes.current, [.ready(BatteryDetails(health: 95, cycles: 232))])
            f.finish(1, .exited(status: 0, output: try profile(health: "1%")))
            t.equal(service.reading(), .ready(BatteryDetails(health: 95, cycles: 232)), "a duplicate late callback is inert")
            t.equal(f.main.count, 0)

            f.clock.access { $0 = 1 }
            t.equal(service.reading(), .pending, "a wall-clock rollback uses its actual bucket")
            f.flush()
            t.equal(f.reader.count, 4)
            f.finish(3, .exited(status: 0, output: try profile(health: "96%", cycles: 233)))
            t.equal(service.reading(), .ready(BatteryDetails(health: 96, cycles: 233)))
            f.clock.access { $0 = .nan }
            t.equal(service.reading(), .ready(BatteryDetails()))
            t.equal(f.reader.count, 4, "an invalid injected clock neither traps nor launches work")
        }

        t.suite("App: battery details provider: synchronous completion before a ticket cannot revive an obsolete request") {
            let f = Fixture()
            defer { f.close() }
            f.reader.immediate = .exited(status: 0, output: try profile())
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let released = Guarded<[Bool]>([])
            f.reader.beforeReturning = { index in
                guard index == 0 else { return }
                entered.signal()
                released.access { $0.append(release.wait(timeout: .now() + 10) == .success) }
            }
            defer { release.signal() }
            t.equal(f.service.reading(), .pending)
            let held = entered.wait(timeout: .now() + 10) == .success
            t.check(held, "completion ran inline, but start has not returned its ticket")
            guard held else { return }
            f.clock.access { $0 = 3_600 }
            t.equal(f.service.reading(), .pending)
            release.signal()
            f.flush()
            t.equal(released.current, [true])
            t.equal(f.reader.count, 2)
            t.equal(f.reader.cancellations(0), 1, "the late-installed obsolete ticket is cancelled")
            t.equal(f.reader.maximumActive, 1)
            t.equal(f.reader.cleanups, 2)
            t.equal(f.service.reading(), .ready(BatteryDetails(health: 94, cycles: 231)))
            t.equal(f.main.count, 1, "only the newest bucket publishes")
            f.main.drain()
            t.equal(f.changes.current, [.ready(BatteryDetails(health: 94, cycles: 231))])

            let stopped = Fixture()
            defer { stopped.close() }
            let stoppedEntered = DispatchSemaphore(value: 0)
            let stoppedRelease = DispatchSemaphore(value: 0)
            let stoppedReleased = Guarded<[Bool]>([])
            stopped.reader.beforeReturning = { _ in
                stoppedEntered.signal()
                stoppedReleased.access { $0.append(stoppedRelease.wait(timeout: .now() + 10) == .success) }
            }
            defer { stoppedRelease.signal() }
            t.equal(stopped.service.reading(), .pending)
            let stoppedHeld = stoppedEntered.wait(timeout: .now() + 10) == .success
            t.check(stoppedHeld)
            guard stoppedHeld else { return }
            stopped.service.stop()
            stoppedRelease.signal()
            stopped.flush()
            t.equal(stoppedReleased.current, [true])
            t.equal(stopped.reader.cancellations(0), 1, "stop also cancels a ticket returned after teardown")
            stopped.finish(.exited(status: 0, output: try profile()))
            t.equal(stopped.service.reading(), .ready(BatteryDetails()))
            t.equal(stopped.rawReads.current, 0)
            t.equal(stopped.main.count, 0)
        }

        t.suite("App: battery details provider: failures and a battery with no metadata finish once without retry loops") {
            let valid = try profile()
            let failures: [Service.ProfileResult] = [
                .failed(.start(EACCES)), .failed(.timedOut), .failed(.outputLimit), .failed(.incompleteOutput),
                .failed(.read(EIO)), .failed(.wait(ECHILD)), .exited(status: 1, output: valid),
                .exited(status: 137, output: valid), .exited(status: 0, output: Data("{".utf8)),
                .exited(status: 0, output: Data(repeating: 32, count: Service.maximumOutputBytes + 1)),
                .exited(status: 0, output: try profile(health: nil, cycles: nil))
            ]
            for failure in failures {
                let f = Fixture()
                defer { f.close() }
                f.reader.immediate = failure
                t.equal(f.service.reading(), .pending)
                f.flush()
                for _ in 0..<3 { t.equal(f.service.reading(), .ready(BatteryDetails())) }
                t.equal(f.reader.count, 1, "a completed missing snapshot is not pending")
                t.equal(f.reader.cleanups, 1)
                t.equal(f.rawReads.current, 1, "one absent raw battery completes the fallback")
                f.main.drain()
                t.equal(f.changes.current, [.ready(BatteryDetails())])
                f.flush()
                t.equal(f.main.count, 0, "the ready notification cannot create a retry loop")
            }
            let f = Fixture()
            defer { f.close() }
            f.reader.immediate = .failed(.timedOut)
            f.raw.access { $0 = raw90 }
            t.equal(f.service.reading(), .pending)
            f.flush()
            t.equal(f.service.reading(), .ready(BatteryDetails(health: 90)), "timeout can use raw health, never raw cycles")
        }

        t.suite("App: battery details provider: stop cancels late work and SystemMonitor adds no second details cache") {
            let f = Fixture()
            defer { f.close() }
            t.equal(f.service.reading(), .pending)
            f.flush()
            f.service.stop()
            f.service.stop()
            t.equal(f.reader.cancellations(0), 1, "stop is idempotent and does not wait for the reader")
            f.finish(.exited(status: 0, output: try profile()))
            t.equal(f.reader.cleanups, 1)
            t.equal(f.rawReads.current, 0)
            t.equal(f.service.reading(), .ready(BatteryDetails()))
            f.clock.access { $0 = 7_200 }
            t.equal(f.service.reading(), .ready(BatteryDetails()))
            f.flush()
            t.equal(f.reader.count, 1)
            t.equal(f.main.count, 0)

            let ready = Fixture()
            defer { ready.close() }
            ready.reader.immediate = .exited(status: 0, output: try profile())
            t.equal(ready.service.reading(), .pending)
            ready.flush()
            t.equal(ready.main.count, 1)
            ready.clock.access { $0 = 3_600 }
            ready.main.drain()
            t.equal(ready.changes.current, [], "a late callback also checks the actual hour before any new question")
            t.equal(ready.service.reading(), .pending)
            ready.flush()
            t.equal(ready.main.count, 1)
            ready.service.stop()
            ready.main.drain()
            t.equal(ready.changes.current, [], "stop invalidates a Main notification already queued")

            let details = Guarded<BatteryDetailsReading>(.pending)
            let detailReads = Guarded(0)
            let batteryReads = Guarded(0)
            let battery = BatteryStatus(percent: 73, isCharging: false, isPluggedIn: false, minutesRemaining: 22)
            let monitor = SystemMonitor(clock: { 1_000 }, readBattery: {
                batteryReads.access { $0 += 1 }; return battery
            }, readBatteryDetails: {
                detailReads.access { $0 += 1 }; return details.current
            })
            t.equal(monitor.batteryDetails(), .pending)
            details.access { $0 = .ready(BatteryDetails(health: 94, cycles: 231)) }
            t.equal(monitor.batteryDetails(), .ready(BatteryDetails(health: 94, cycles: 231)),
                    "the first pending answer is never cached by SystemMonitor")
            details.access { $0 = .ready(BatteryDetails()) }
            t.equal(monitor.batteryDetails(), .ready(BatteryDetails()))
            t.equal(detailReads.current, 3)
            t.equal(monitor.battery(), battery)
            t.equal(monitor.battery(), battery)
            t.equal(batteryReads.current, 1, "legacy battery retains its existing five-second cache")
            monitor.invalidateBatteryCache()
            t.equal(monitor.batteryDetails(), .ready(BatteryDetails()))
            t.equal(detailReads.current, 4, "power invalidation adds no independent metadata TTL")
            t.equal(monitor.battery(), battery)
            t.equal(batteryReads.current, 2)
        }

        t.suite("App: battery details provider: fixed local children prove bounded output timeout cancellation and group cleanup") {
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]
                                ?? FileManager.default.temporaryDirectory.path, isDirectory: true)
                .appendingPathComponent("DeskBatteryDetailsChildren-\(getpid())-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let json = #"{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_health_maximum_capacity":"94%","sppower_battery_cycle_count":231}}]}"#
            let successful = Child(arguments: ["-c", #"printf '%s' '{"SPPowerDataType":[{"sppower_battery_health_info":{"sppower_battery_health_maximum_capacity":"94%","sppower_battery_cycle_count":231}}]}'; printf 'discarded stderr' >&2"#])
            defer { successful.ticket.cancel() }
            t.equal(successful.finish(t), .exited(status: 0, output: Data(json.utf8)))

            let nonzero = Child(arguments: ["-c", #"printf '%s' '{"SPPowerDataType":[]}'; exit 7"#])
            defer { nonzero.ticket.cancel() }
            t.equal(nonzero.finish(t), .exited(status: 7, output: Data(#"{"SPPowerDataType":[]}"#.utf8)))

            let excessive = Child(executable: "/usr/bin/yes", arguments: ["bounded-profile-output"])
            defer { excessive.ticket.cancel() }
            t.equal(excessive.finish(t), .failed(.outputLimit), "overflow is a failure, never a truncated success")

            let absent = Child(executable: directory.appendingPathComponent("not-an-executable").path, arguments: [])
            defer { absent.ticket.cancel() }
            t.equal(absent.finish(t), .failed(.start(ENOENT)), "spawn failure also completes once")

            // All scripts are fixed; $1 is a test-owned file path passed as an argument, never interpolated into code.
            let scripts: [(String, String, TimeInterval, Bool, Service.ProfileResult)] = [
                ("held-stdout", #"/bin/sleep 30 & printf '%s %s\n' "$$" "$!" > "$1"; exit 0"#,
                 5, false, .failed(.incompleteOutput)),
                ("closed-stdout", #"/bin/sleep 30 >/dev/null 2>&1 & printf '%s %s\n' "$$" "$!" > "$1"; printf '{}'; exit 0"#,
                 5, false, .exited(status: 0, output: Data("{}".utf8))),
                ("timeout", #"/bin/sleep 30 & printf '%s %s\n' "$$" "$!" > "$1"; wait"#,
                 1, false, .failed(.timedOut)),
                ("cancel", #"/bin/sleep 30 & printf '%s %s\n' "$$" "$!" > "$1"; wait"#,
                 5, true, .failed(.cancelled))
            ]
            for (name, script, timeout, cancel, expected) in scripts {
                let path = directory.appendingPathComponent(name + ".pids")
                let child = Child(arguments: ["-c", script, "battery-details-test", path.path], timeout: timeout)
                defer { child.ticket.cancel() }
                let hasIDs = waitFor { processIDs(path) != nil }
                t.check(hasIDs, "\(name): leader and child identities were recorded before exit")
                if cancel { child.ticket.cancel(); child.ticket.cancel() }
                t.equal(child.finish(t), expected, name)
                if let pids = processIDs(path) { checkReapedGroup(t, pids: pids) }
            }
        }
    }
}
