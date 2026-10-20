import Foundation
import DesksetCore

enum NetworkStatisticsSelfTests {
    static func run(_ t: AppTestRunner) {
        samplingTests(t)
        persistenceTests(t)
        lifecycleTests(t)
    }

    private static func samplingTests(_ t: AppTestRunner) {
        t.suite("App: Network statistics: raw caching and concurrent cumulative readers share each sample") {
            let fixture = Fixture()
            let statistics = fixture.make()
            fixture.set(["en0": counter(100, 200)])
            t.equal(statistics.rawSnapshot().counters["en0"], counter(100, 200))
            fixture.set(["en0": counter(200, 300)])
            t.equal(statistics.rawSnapshot().counters["en0"], counter(100, 200), "raw cache lasts half a second")
            t.equal(statistics.cumulativeCounters(interface: nil), counter(0, 0), "first cumulative read forces a fresh baseline")
            t.equal(fixture.reads.current, 2)
            fixture.advance(["en0": counter(250, 380)])
            t.equal(statistics.rawSnapshot().counters["en0"], counter(250, 380))
            let results = SharedServiceThreadingSelfTests.Collected<NetworkCounters>()
            t.check(ServiceThreadingSelfTests.onThreads(6) { _ in
                for _ in 0..<30 { results.add(statistics.cumulativeCounters(interface: "en0")) }
            })
            t.check(results.all.allSatisfy { $0 == counter(50, 80) })
            t.equal(fixture.reads.current, 3, "all readers reuse the fresh sample without adding it again")
            t.equal(fixture.scheduler.entries.current.count, 0, "an unconfigured host never schedules background work")
            t.check(statistics.saveAndStop())
        }

        t.suite("App: Network statistics: physical totals include every NIC once and explicit virtual totals stay separate") {
            let fixture = Fixture()
            let statistics = fixture.make()
            statistics.configure(fileURL: file(t, "multiple-nics"))
            fixture.set(["en0": counter(100, 200), "en1": counter(50, 80), "utun0": counter(500, 600)])
            t.equal(statistics.cumulativeCounters(interface: "en0"), counter(0, 0))
            fixture.advance(["en0": counter(110, 230), "en1": counter(70, 120), "utun0": counter(600, 800)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(30, 70))
            t.equal(statistics.cumulativeCounters(interface: "en0"), counter(10, 30))
            t.equal(statistics.cumulativeCounters(interface: "en1"), counter(20, 40))
            t.equal(statistics.cumulativeCounters(interface: "utun0"), counter(100, 200))
            t.equal(fixture.reads.current, 2)
            t.equal(fixture.scheduler.entries.current.map(\.interval), [120])
            t.check(statistics.saveAndStop())
        }

        t.suite("App: Network statistics: Reset bypasses cached bytes and waits for a successful new baseline") {
            let fixture = Fixture()
            let statistics = fixture.make()
            fixture.set(["en0": counter(100, 100)])
            _ = statistics.cumulativeCounters(interface: nil)
            fixture.advance(["en0": counter(200, 200)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(100, 100))
            fixture.set(["en0": counter(250, 250)])
            statistics.reset()
            t.equal(statistics.cumulativeCounters(interface: nil), counter(0, 0), "Reset does not reuse the cached 200-byte baseline")
            fixture.advance(["en0": counter(275, 275)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(25, 25))

            fixture.sample.access { $0 = nil }
            statistics.reset()
            t.equal(statistics.rawSnapshot().counters["en0"], counter(275, 275), "raw callers retain the last sample on failure")
            fixture.advance(["en0": counter(300, 300)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(0, 0), "failed Reset leaves a pending baseline")
            fixture.advance(["en0": counter(325, 325)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(25, 25))

            fixture.set(["en0": counter(325, 325)], unavailable: ["en0"])
            statistics.reset()
            fixture.advance(["en0": counter(400, 400)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(0, 0), "per-interface fallback cannot establish a reset baseline")
            fixture.advance(["en0": counter(410, 415)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(10, 15))
            t.equal(fixture.scheduler.entries.current.count, 0, "Reset alone never creates periodic work")
            t.check(statistics.saveAndStop())
        }

        t.suite("App: Network statistics: disconnect and counter rollback preserve accumulated bytes") {
            let fixture = Fixture()
            let statistics = fixture.make()
            fixture.set(["en0": counter(100, 100)])
            _ = statistics.cumulativeCounters(interface: nil)
            fixture.advance(["en0": counter(150, 160)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(50, 60))
            fixture.advance([:])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(50, 60), "disconnected NIC totals remain")
            fixture.advance(["en0": counter(10_000, 10_000)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(50, 60), "returning NIC starts a fresh baseline")
            fixture.advance(["en0": counter(10_010, 10_020)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(60, 80))
            fixture.advance(["en0": counter(5, 7)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(60, 80), "counter rollback does not underflow")
            fixture.advance(["en0": counter(10, 9)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(65, 82))
            t.check(statistics.saveAndStop())
        }

        t.suite("App: Network statistics: SystemMonitor keeps raw speed counters independent of cumulative Reset") {
            let fixture = Fixture()
            let monitor = SystemMonitor(clock: { fixture.time.current }, networkSampler: fixture.read,
                                        networkSchedule: fixture.scheduler.schedule)
            monitor.configureNetworkStatistics(fileURL: file(t, "monitor"))
            fixture.set(["en0": counter(100, 200), "en1": counter(300, 400)])
            t.equal(monitor.networkCounters(interface: nil), counter(400, 600))
            t.equal(monitor.cumulativeNetworkCounters(interface: "en0"), counter(0, 0))
            fixture.advance(["en0": counter(150, 260), "en1": counter(330, 420)])
            t.equal(monitor.networkCounters(interface: "en0"), counter(150, 260))
            t.equal(monitor.cumulativeNetworkCounters(interface: nil), counter(80, 80))
            monitor.resetNetworkStatistics()
            t.equal(monitor.networkCounters(interface: nil), counter(480, 680))
            t.equal(monitor.cumulativeNetworkCounters(interface: nil), counter(0, 0))
            t.equal(fixture.scheduler.entries.current.count, 1, "Reset preserves the existing timer")
            t.check(monitor.saveNetworkStatisticsAndStop())
        }
    }

    private static func persistenceTests(_ t: AppTestRunner) {
        t.suite("App: Network statistics: raw reads and standalone Reset never activate the periodic sampler") {
            let fixture = Fixture()
            let statistics = fixture.make()
            let url = file(t, "lazy")
            statistics.configure(fileURL: url)
            fixture.set(["en0": counter(100, 100)])
            _ = statistics.rawSnapshot()
            t.check(!FileManager.default.fileExists(atPath: url.path), "configuration and raw reads do not create a statistics file")
            t.equal(fixture.scheduler.entries.current.count, 0)
            statistics.reset()
            t.equal(fixture.scheduler.entries.current.count, 0)
            t.check(statistics.saveAndStop())
            t.equal(try storedCounters(url), [:], "Reset can persist zero without activating collection")

            let inactive = fixture.make()
            let inactiveURL = file(t, "inactive-exit")
            inactive.configure(fileURL: inactiveURL)
            t.check(inactive.saveAndStop())
            t.check(!FileManager.default.fileExists(atPath: inactiveURL.path), "unused statistics do not create a file on exit")
        }

        t.suite("App: Network statistics: the activated session keeps sampling and saves across restarts") {
            let fixture = Fixture()
            let statistics = fixture.make()
            let url = file(t, "restart")
            statistics.configure(fileURL: url)
            fixture.set(["en0": counter(100, 200)])
            _ = statistics.cumulativeCounters(interface: nil)
            fixture.set(["en0": counter(150, 260)])
            fixture.scheduler.fire(0)
            t.check(AppSelfTest.spin { (try? storedCounters(url)["en0"]) == counter(50, 60) }, "timer saves without another measure read")
            fixture.set(["en0": counter(175, 290)])
            fixture.scheduler.fire(0)
            t.check(AppSelfTest.spin { (try? storedCounters(url)["en0"]) == counter(75, 90) })
            fixture.set(["en0": counter(200, 300)])
            t.check(statistics.saveAndStop())
            t.equal(try storedCounters(url)["en0"], counter(100, 100), "exit includes the final fresh sample")
            t.check(fixture.scheduler.entries.current[0].work.isCancelled)

            let next = Fixture()
            let reopened = next.make()
            reopened.configure(fileURL: url)
            next.set(["en0": counter(100_000, 200_000)])
            t.equal(reopened.cumulativeCounters(interface: nil), counter(100, 100), "restart restores totals without adding downtime or bytes since boot")
            next.advance(["en0": counter(100_025, 200_035)])
            t.equal(reopened.cumulativeCounters(interface: nil), counter(125, 135))
            t.check(reopened.saveAndStop())
        }

        t.suite("App: Network statistics: corrupt files and failed writes report errors without preventing readings") {
            let fixture = Fixture()
            let url = file(t, "corrupt")
            let corrupt = Data("not a statistics document".utf8)
            try corrupt.write(to: url)
            let statistics = fixture.make()
            statistics.configure(fileURL: url)
            t.equal(fixture.errors.current.count, 1)
            t.equal(try Data(contentsOf: url), corrupt, "loading alone leaves an unreadable file intact")
            fixture.set(["en0": counter(10, 20)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(0, 0))
            fixture.advance(["en0": counter(15, 27)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(5, 7))
            t.check(statistics.saveAndStop())
            t.equal(try storedCounters(url)["en0"], counter(5, 7))

            let failing = fixture.make(fileIO: .init(read: { _ in nil }, write: { _, _ in throw TestError.write }))
            failing.configure(fileURL: file(t, "failed-write"))
            _ = failing.cumulativeCounters(interface: nil)
            t.check(!failing.saveAndStop(), "a real write failure is returned to the primary app")
            t.equal(fixture.errors.current.count, 2)
            t.check(fixture.errors.current.last?.contains("Unable to save network statistics") == true)
        }

        t.suite("App: Network statistics: a write already in progress cannot overwrite Reset or final exit") {
            let fixture = Fixture()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let first = Guarded(true)
            let writes = Guarded(0)
            let url = file(t, "write-reset")
            let statistics = fixture.make(fileIO: .init(read: NetworkStatistics.FileIO.live.read, write: { data, target in
                let hold = first.access { value -> Bool in let old = value; value = false; return old }
                if hold { entered.signal(); _ = release.wait(timeout: .now() + 15) }
                try NetworkStatistics.FileIO.live.write(data, target)
                writes.access { $0 += 1 }
            }))
            statistics.configure(fileURL: url)
            fixture.set(["en0": counter(100, 100)])
            _ = statistics.cumulativeCounters(interface: nil)
            fixture.set(["en0": counter(150, 150)])
            fixture.scheduler.fire(0)
            let started = entered.wait(timeout: .now() + 10) == .success
            t.check(started, "the periodic write is held after its snapshot was captured")
            guard started else { release.signal(); _ = statistics.saveAndStop(); return }
            fixture.set(["en0": counter(200, 200)])
            statistics.reset()
            fixture.advance(["en0": counter(225, 230)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(25, 30))
            release.signal()
            t.check(statistics.saveAndStop())
            t.equal(try storedCounters(url)["en0"], counter(25, 30))
            let completedWrites = writes.current
            fixture.scheduler.fire(0, bypassCancellation: true)
            statistics.reset()
            t.equal(statistics.cumulativeCounters(interface: nil), counter(25, 30), "late calls cannot reopen the stopped collector")
            t.check(statistics.saveAndStop())
            t.equal(writes.current, completedWrites, "the exit barrier rejects late timer writes")
        }
    }

    private static func lifecycleTests(_ t: AppTestRunner) {
        for resetWhileLoading in [false, true] {
            t.suite("App: Network statistics: file loading preserves concurrent \(resetWhileLoading ? "Reset" : "sampling")") {
                let fixture = Fixture()
                let url = file(t, "loading")
                try Data(#"{"version":1,"interfaces":{"en0":{"received":100,"sent":200}}}"#.utf8).write(to: url)
                let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let completed = DispatchSemaphore(value: 0)
                let statistics = fixture.make(fileIO: .init(read: { target in
                    let data = try NetworkStatistics.FileIO.live.read(target)
                    entered.signal()
                    _ = release.wait(timeout: .now() + 15)
                    return data
                }, write: NetworkStatistics.FileIO.live.write))
                let thread = Thread { statistics.configure(fileURL: url); completed.signal() }
                thread.start()
                let started = entered.wait(timeout: .now() + 10) == .success
                t.check(started)
                guard started else { release.signal(); _ = completed.wait(timeout: .now() + 10); _ = statistics.saveAndStop(); return }
                fixture.set(["en0": counter(100, 100)])
                _ = statistics.cumulativeCounters(interface: nil)
                fixture.advance(["en0": counter(125, 130)])
                t.equal(statistics.cumulativeCounters(interface: nil), counter(25, 30))
                if resetWhileLoading {
                    statistics.reset()
                    fixture.advance(["en0": counter(135, 150)])
                    t.equal(statistics.cumulativeCounters(interface: nil), counter(10, 20))
                }
                t.equal(fixture.scheduler.entries.current.count, 0, "the timer waits for configuration to finish")
                release.signal()
                t.check(completed.wait(timeout: .now() + 10) == .success)
                let expected = resetWhileLoading ? counter(10, 20) : counter(125, 230)
                t.equal(statistics.cumulativeCounters(interface: nil), expected,
                        "loaded totals are merged with fresh deltas unless Reset invalidated them")
                t.equal(fixture.scheduler.entries.current.count, 1)
                t.check(statistics.saveAndStop())
                t.equal(try storedCounters(url)["en0"], expected)
            }
        }

        t.suite("App: Network statistics: an inline scheduler runs outside the network lock and survives Reset") {
            let fixture = Fixture()
            fixture.scheduler.inline = true
            let statistics = fixture.make()
            statistics.configure(fileURL: file(t, "inline"))
            fixture.set(["en0": counter(100, 100)])
            t.equal(statistics.cumulativeCounters(interface: nil), counter(0, 0))
            t.equal(fixture.scheduler.entries.current.count, 1)
            t.equal(fixture.reads.current, 2, "the inline callback safely takes a fresh sample")
            let cancelled = Guarded(false)
            fixture.scheduler.entries.current[0].work.setCancelHandler { [weak statistics] in
                _ = statistics?.rawSnapshot()
                cancelled.access { $0 = true }
            }
            statistics.reset()
            t.check(!fixture.scheduler.entries.current[0].work.isCancelled)
            fixture.set(["en0": counter(110, 120)])
            fixture.scheduler.fire(0)
            t.equal(statistics.cumulativeCounters(interface: nil), counter(10, 20))
            t.check(statistics.saveAndStop())
            t.check(cancelled.current, "cancellation can safely re-enter raw sampling outside the network lock")
        }

        for reconfigure in [false, true] {
            t.suite("App: Network statistics: delayed timer creation is cancelled after \(reconfigure ? "reconfiguration" : "exit")") {
                let fixture = Fixture()
                let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                let completed = DispatchSemaphore(value: 0)
                let first = Guarded(true)
                fixture.scheduler.onCreate = {
                    let hold = first.access { value -> Bool in let old = value; value = false; return old }
                    if hold { entered.signal(); _ = release.wait(timeout: .now() + 15) }
                }
                let statistics = fixture.make()
                let original = file(t, "old-timer"), replacement = file(t, "new-timer")
                statistics.configure(fileURL: original)
                fixture.set(["en0": counter(100, 100)])
                let thread = Thread {
                    _ = statistics.cumulativeCounters(interface: nil)
                    completed.signal()
                }
                thread.start()
                let started = entered.wait(timeout: .now() + 10) == .success
                t.check(started)
                guard started else { release.signal(); _ = completed.wait(timeout: .now() + 10); _ = statistics.saveAndStop(); return }
                if reconfigure { statistics.configure(fileURL: replacement) }
                else { t.check(statistics.saveAndStop()) }
                release.signal()
                t.check(completed.wait(timeout: .now() + 10) == .success)
                guard let old = fixture.scheduler.entries.current.first else { return t.check(false, "timer handle exists") }
                t.check(old.work.isCancelled, "a late handle is not adopted into the new lifecycle")
                let reads = fixture.reads.current
                fixture.scheduler.fire(0, bypassCancellation: true)
                t.equal(fixture.reads.current, reads, "an already-dispatched old callback cannot sample")
                if reconfigure {
                    t.check(!FileManager.default.fileExists(atPath: replacement.path))
                    fixture.set(["en0": counter(200, 200)])
                    t.equal(statistics.cumulativeCounters(interface: nil), counter(0, 0))
                    t.equal(fixture.scheduler.entries.current.count, 2)
                    fixture.advance(["en0": counter(210, 220)])
                    t.equal(statistics.cumulativeCounters(interface: nil), counter(10, 20))
                }
                t.check(statistics.saveAndStop())
                if reconfigure { t.equal(try storedCounters(replacement)["en0"], counter(10, 20)) }
            }
        }
    }

    private enum TestError: Error { case write }

    private final class ManualScheduler {
        struct Entry {
            var interval: TimeInterval
            var callback: () -> Void
            var work: SkinScheduledWork
        }
        let entries = Guarded<[Entry]>([])
        var inline = false
        var onCreate: (() -> Void)?

        func schedule(_ interval: TimeInterval, _ callback: @escaping () -> Void) -> SkinScheduledWork {
            let work = SkinScheduledWork(repeats: true, callback)
            entries.access { $0.append(Entry(interval: interval, callback: callback, work: work)) }
            if inline { work.fire() }
            onCreate?()
            return work
        }

        func fire(_ index: Int, bypassCancellation: Bool = false) {
            let current = entries.current
            guard current.indices.contains(index) else { return }
            let entry = current[index]
            if bypassCancellation { entry.callback() } else { entry.work.fire() }
        }
    }

    private final class Fixture {
        let time = Guarded<TimeInterval>(0)
        let sample = Guarded<NetworkStatistics.Sample?>(NetworkStatistics.Sample())
        let reads = Guarded(0)
        let errors = Guarded<[String]>([])
        let scheduler = ManualScheduler()

        func read(_ fallback: NetworkStatistics.Sample) -> NetworkStatistics.Sample? {
            reads.access { $0 += 1 }
            return sample.current
        }

        func make(fileIO: NetworkStatistics.FileIO = .live) -> NetworkStatistics {
            NetworkStatistics(clock: { self.time.current }, sampler: read, schedule: scheduler.schedule,
                              fileIO: fileIO, report: { message in self.errors.access { $0.append(message) } })
        }

        func set(_ counters: [String: NetworkCounters], unavailable: Set<String> = []) {
            sample.access { $0 = NetworkStatistics.Sample(counters: counters, active: counters.keys.sorted(),
                                                          flags: counters.mapValues { _ in 1 }, unavailable: unavailable) }
        }

        func advance(_ counters: [String: NetworkCounters]) {
            set(counters)
            time.access { $0 += 1 }
        }
    }

    private static func counter(_ received: UInt64, _ sent: UInt64) -> NetworkCounters {
        NetworkCounters(received: received, sent: sent)
    }

    private static func file(_ t: AppTestRunner, _ label: String) -> URL {
        t.temporaryDirectory("network-statistics-\(label)").appendingPathComponent("statistics.json")
    }

    private static func storedCounters(_ url: URL) throws -> [String: NetworkCounters] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let interfaces = object?["interfaces"] as? [String: [String: NSNumber]] else { return [:] }
        return interfaces.mapValues { counter($0["received"]?.uint64Value ?? 0, $0["sent"]?.uint64Value ?? 0) }
    }
}
