import AppKit
import DesksetCore

enum NetworkStatisticsRuntimeSelfTests {
    static func run(_ t: AppTestRunner) {
        for mode in [SkinThreading.main, .engine, .pool] {
            t.suite("App: Network statistics: ResetStats precedes the next cumulative read (\(mode))") {
                let system = TestSystem()
                guard let app = try fixture(t, mode, system) else { return }
                guard let source = load(t, app, "Source"), let peer = load(t, app, "Peer") else { return }
                for c in [source, peer] {
                    t.equal(c.runtime.exclusive(timeout: 30) { $0.system === system }, true,
                            "the app's provider belongs to every runtime")
                    t.equal(values(c), [300, 500, 800])
                }

                // No main run-loop turn between the command and the read: the engine must not defer reset to main.
                source.runtime.send(.execute("[!ResetStats][!UpdateMeasure CumIn][!UpdateMeasure CumOut]"
                    + "[!UpdateMeasure CumTotal]", section: nil))
                t.equal(values(source), [0, 0, 0], "the following commands see reset on their own executor")
                t.equal(system.resetCount, 1)
                t.equal(values(peer), [300, 500, 800], "reset does not force unrelated measure updates")
                peer.runtime.send(.execute("[!UpdateMeasure CumIn][!UpdateMeasure CumOut][!UpdateMeasure CumTotal]",
                                           section: nil))
                t.equal(values(peer), [0, 0, 0], "the peer's next read sees the same reset")
                t.equal(system.networkCounters(interface: nil), NetworkCounters(received: 1_000, sent: 2_000),
                        "the original speed counters retain their values")
                t.check(source.runtime.snapshot.issues.allSatisfy { !$0.localizedCaseInsensitiveContains("ResetStats") },
                        "a supported bang is not a compatibility note")
            }

            t.suite("App: Network statistics: recording, retirement and closed runtimes cannot reset (\(mode))") {
                let system = TestSystem()
                guard let app = try fixture(t, mode, system), let source = load(t, app, "Source") else { return }
                let recording = RecordingSideEffects()
                _ = source.runtime.exclusive(timeout: 30) { $0.sideEffects = recording }
                source.runtime.send(.execute("[!ResetStats][!UpdateMeasure CumTotal]", section: nil))
                t.equal(values(source), [300, 500, 800])
                t.equal(recording.records, [.hostBang("!ResetStats")])
                t.equal(system.resetCount, 0, "recording does not touch the provider")

                _ = source.runtime.exclusive(timeout: 30) { $0.sideEffects = LiveSideEffects.shared }
                source.retiredByLayout = true
                source.runtime.retireForLayout()
                source.runtime.send(.execute("[!ResetStats]", section: nil))
                _ = source.runtime.exclusive(timeout: 30) { _ in true }
                t.equal(system.resetCount, 0, "a retired runtime cannot introduce a late reset")
                app.deactivate(config: source.config)
                t.check(AppSelfTest.spin(timeout: 30) { source.hasClosed }, "the fixture closes")
                source.runtime.send(.execute("[!ResetStats]", section: nil))
                _ = source.runtime.exclusive(timeout: 30) { _ in true }
                t.equal(system.resetCount, 0, "a closed runtime cannot reset")
            }

            t.suite("App: Network statistics: real close actions reset before shutdown saving (\(mode))") {
                let system = TestSystem()
                guard let app = try fixture(t, mode, system, resetOnClose: true),
                      let source = load(t, app, "Source") else { return }
                source.retiredByLayout = true
                source.runtime.retireForLayout()
                t.equal(app.stopAllForTermination(budget: 30), [], "the actual close action finishes before saving")
                t.equal(system.resetCount, 1, "layout retirement permits the real OnCloseAction")
                t.equal(system.cumulativeNetworkCounters(interface: nil), NetworkCounters())
                t.equal(system.networkCounters(interface: nil), NetworkCounters(received: 1_000, sent: 2_000))
                source.runtime.send(.execute("[!ResetStats]", section: nil))
                _ = source.runtime.exclusive(timeout: 30) { _ in true }
                t.equal(system.resetCount, 1, "a later command cannot repeat the close action's reset")
            }
        }
    }

    private static func fixture(_ t: AppTestRunner, _ mode: SkinThreading,
                                _ system: TestSystem, resetOnClose: Bool = false) throws -> AppController? {
        guard let app = try AppSelfTest.makeApp(t, threading: mode, system: system) else { return nil }
        t.atSuiteEnd {
            let threads = (app.engineThread.map { [$0] } ?? []) + (app.skinThreadPool?.activeWorkers ?? [])
            app.stopAllForTermination()
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { threads.allSatisfy(\.hasExited) }, "fixture threads stopped")
        }
        for name in ["Source", "Peer"] {
            let folder = app.skinsDirectory.appendingPathComponent("Stats/\(name)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let text = resetOnClose ? skinText.replacingOccurrences(of: "Update=-1", with: "Update=-1\nOnCloseAction=[!ResetStats]") : skinText
            try text.write(to: folder.appendingPathComponent("Counter.ini"), atomically: true, encoding: .utf8)
        }
        app.rescanLibrary()
        return app
    }

    private static func load(_ t: AppTestRunner, _ app: AppController, _ name: String) -> SkinWindowController? {
        guard let c = app.activate(config: "Stats\\\(name)", file: "Counter.ini") else {
            t.check(false, "the fixture activates")
            return nil
        }
        guard AppSelfTest.spin(timeout: 30, until: { c.isStarted }) else {
            t.check(false, "the fixture starts")
            return nil
        }
        return c
    }

    private static func values(_ c: SkinWindowController) -> [Double]? {
        c.runtime.exclusive(timeout: 30) { skin in
            ["CumIn", "CumOut", "CumTotal"].map { skin.measure(named: $0)?.value ?? -1 }
        }
    }

    private static let skinText = """
        [Rainmeter]
        Update=-1
        [CumIn]
        Measure=NetIn
        Interface=0
        Cumulative=1
        [CumOut]
        Measure=NetOut
        Interface=0
        Cumulative=1
        [CumTotal]
        Measure=NetTotal
        Interface=0
        Cumulative=1
        [Meter]
        Meter=String
        Text=Stats
        W=80
        H=24
        """

    /// Shared by the runtime and native Settings tests; no operating-system reads, timers or files.
    final class TestSystem: SystemDataSource {
        private struct State {
            var totals = NetworkCounters(received: 300, sent: 500)
            var resets = 0
        }
        private let state = Guarded(State())
        var resetCount: Int { state.access { $0.resets } }
        func setTotals(_ value: NetworkCounters) { state.access { $0.totals = value } }
        var processorCount: Int { 1 }
        func cpuUsage(processor: Int) -> Double { 0 }
        func memoryStatus() -> MemoryStatus { MemoryStatus() }
        func networkInterfaces() -> [String] { ["test0"] }
        func bestNetworkInterface() -> String? { "test0" }
        func networkCounters(interface: String?) -> NetworkCounters {
            NetworkCounters(received: 1_000, sent: 2_000)
        }
        func cumulativeNetworkCounters(interface: String?) -> NetworkCounters { state.access { $0.totals } }
        func resetNetworkStatistics() { state.access { $0.totals = NetworkCounters(); $0.resets += 1 } }
        func diskSpace(path: String) -> (total: Double, free: Double)? { nil }
        func uptime() -> TimeInterval { 0 }
        func battery() -> BatteryStatus? { nil }
        func isProcessRunning(_ name: String) -> Bool { false }
        func sysInfo(type: String, data: String) -> (number: Double, string: String?)? { nil }
    }
}
