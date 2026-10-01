import AppKit
import DesksetCore

enum SkinWorkWatchdogSelfTests {
    static func run(_ t: AppTestRunner) {
        boundaryTests(t)
        lifetimeTests(t)
        timerTests(t)
        blockedWorkerTests(t)
        runtimeTests(t)
    }

    private static func makeClock() -> SteppedSkinClock {
        SteppedSkinClock(start: Date(timeIntervalSince1970: 0), timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    private static func boundaryTests(_ t: AppTestRunner) {
        t.suite("App: skin watchdog: nested work keeps its first start and reports only once") {
            let clock = makeClock()
            let reports = Guarded<[SkinWorkWatchdog.Report]>([])
            let watchdog = SkinWorkWatchdog(clock: clock.clock, automaticChecks: false) { report in
                reports.access { $0.append(report) }
            }
            let activity = SkinWorkWatchdog.Activity(watchdog: watchdog, config: "Watchdog\\Nested")
            activity.begin()
            clock.advance(by: 1.5)
            activity.begin(.drawing)
            clock.advance(by: 0.5)
            watchdog.check()
            t.equal(reports.current.count, 0, "exactly two seconds has not crossed the limit")
            clock.advance(by: 0.01)
            watchdog.check()
            t.equal(reports.current.count, 1)
            t.equal(reports.current.first?.config, "Watchdog\\Nested")
            t.equal(reports.current.first?.kind, .work, "nested drawing does not reset the outer work")
            t.close(reports.current.first?.duration ?? 0, 2.01)
            activity.end()
            t.equal(watchdog.activeCount, 1, "the outer work is still running")
            clock.advance(by: 10)
            watchdog.check()
            activity.end()
            t.equal(reports.current.count, 1, "neither later polls nor completion log it again")
            t.equal(watchdog.activeCount, 0)

            activity.begin(.drawing)
            clock.advance(by: 2.5)
            activity.end()
            t.equal(reports.current.count, 2, "long work completed between polls is still reported")
            t.equal(reports.current.last?.kind, .drawing)
            t.close(reports.current.last?.duration ?? 0, 2.5)
            watchdog.check()
            t.equal(reports.current.count, 2)
            t.equal(reports.current.last?.message, "Skin worker busy for 2500 ms (drawing)")
        }
    }

    private static func lifetimeTests(_ t: AppTestRunner) {
        t.suite("App: skin watchdog: releasing one busy skin leaves the other watched") {
            let clock = makeClock()
            let reports = Guarded<[SkinWorkWatchdog.Report]>([])
            let watchdog = SkinWorkWatchdog(clock: clock.clock, automaticChecks: false) { report in
                reports.access { $0.append(report) }
            }
            var first: SkinWorkWatchdog.Activity? = .init(watchdog: watchdog, config: "Watchdog\\First")
            var second: SkinWorkWatchdog.Activity? = .init(watchdog: watchdog, config: "Watchdog\\Second")
            weak var releasedFirst = first
            weak var releasedSecond = second
            first?.begin()
            clock.advance(by: 0.5)
            second?.begin(.drawing)
            t.equal(watchdog.activeCount, 2)
            clock.advance(by: 1.6)
            watchdog.check()
            t.equal(reports.current.map(\.config), ["Watchdog\\First"])
            first = nil
            t.check(releasedFirst == nil, "the watchdog does not retain an active owner")
            t.equal(watchdog.activeCount, 1)
            clock.advance(by: 0.5)
            watchdog.check()
            t.equal(reports.current.map(\.config), ["Watchdog\\First", "Watchdog\\Second"])
            second = nil
            t.check(releasedSecond == nil)
            clock.advance(by: 1_000)
            watchdog.check()
            t.equal(watchdog.activeCount, 0)
            t.equal(reports.current.count, 2, "released work produces no later report")
        }
    }

    private static func timerTests(_ t: AppTestRunner) {
        t.suite("App: skin watchdog: short interleaved work shares one timer and idle stops it") {
            let clock = makeClock()
            weak var released: SkinWorkWatchdog?
            do {
                // Only the automatic checker waits. Main-thread clock reads and explicit checks still run, so a
                // slow runner crossing the timer's first deadline cannot change these deterministic timer counts.
                let automaticChecks = DispatchGroup()
                automaticChecks.enter()
                defer { automaticChecks.leave() }
                var testClock = clock.clock
                let uptime = testClock.uptime
                testClock.uptime = {
                    if !Thread.isMainThread { automaticChecks.wait() }
                    return uptime()
                }
                autoreleasepool {
                    let monitor = SkinWorkWatchdog(clock: testClock)
                    released = monitor
                    t.check(!monitor.hasTimer, "cold start never arms a timer")
                    var first: SkinWorkWatchdog.Activity? = .init(watchdog: monitor, config: "Watchdog\\First")
                    var second: SkinWorkWatchdog.Activity? = .init(watchdog: monitor, config: "Watchdog\\Second")
                    for _ in 0..<10_000 {
                        first?.begin()
                        second?.begin()
                        first?.end()
                        second?.end()
                    }
                    t.equal(monitor.activeCount, 0)
                    t.equal(monitor.timerStarts, 1, "finishing short work never stops and restarts the timer")
                    t.check(monitor.hasTimer, "the next check decides whether the worker stayed idle")
                    monitor.check()
                    t.check(!monitor.hasTimer)
                    clock.advance(by: 1_000)
                    monitor.check()
                    t.equal(monitor.timerStarts, 1, "long idle time schedules nothing")
                    first?.begin()
                    second?.begin()
                    first = nil
                    monitor.check()
                    t.check(monitor.hasTimer, "another skin is still active")
                    t.equal(monitor.timerStarts, 2, "new work after idle starts one timer")
                    second = nil
                    monitor.check()
                    t.check(!monitor.hasTimer)
                }
            }
            t.check(AppSelfTest.spin(timeout: 30) { released == nil }, "the timer never keeps an idle monitor alive")
        }
    }

    private static func blockedWorkerTests(_ t: AppTestRunner) {
        t.suite("App: skin watchdog: the shared timer reports while the worker and main thread cannot answer") {
            let clock = makeClock()
            let reports = Guarded<[SkinWorkWatchdog.Report]>([])
            let reported = DispatchSemaphore(value: 0)
            let watchdog = SkinWorkWatchdog(clock: clock.clock) { report in
                reports.access { $0.append(report) }
                reported.signal()
            }
            let activity = SkinWorkWatchdog.Activity(watchdog: watchdog, config: "Watchdog\\Blocked")
            let executor = SkinThreadExecutor(name: "Skin watchdog test")
            let started = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            let ended = DispatchSemaphore(value: 0)
            defer { gate.signal(); executor.stop() }
            executor.async {
                activity.begin()
                started.signal()
                _ = gate.wait(timeout: .now() + 30)
                activity.end()
                ended.signal()
            }
            t.check(started.wait(timeout: .now() + 30) == .success, "work has begun")
            clock.advance(by: 3)
            // Deliberately do not pump the main run loop: neither main nor the watched executor runs the check.
            t.check(reported.wait(timeout: .now() + 30) == .success, "the independent timer reports the busy skin")
            t.equal(reports.current.count, 1)
            t.equal(reports.current.first?.config, "Watchdog\\Blocked")
            gate.signal()
            t.check(ended.wait(timeout: .now() + 30) == .success, "the worker can finish")
            watchdog.check()
            t.equal(reports.current.count, 1, "completion does not duplicate the report")
            t.check(!watchdog.hasTimer)
        }
    }

    private static func runtimeTests(_ t: AppTestRunner) {
        t.suite("App: skin watchdog: Core work, runtime messages, callbacks, drawing and close are covered") {
            MeasureRegistry.registerPlugin("DesksetWatchdogProbe", WorkProbe.self)
            let root = try writeSkin(t)
            let executor = SkinThreadExecutor(name: "Skin watchdog runtime test")
            defer { executor.stop() }
            let clock = makeClock()
            let reports = Guarded<[SkinWorkWatchdog.Report]>([])
            let watchdog = SkinWorkWatchdog(clock: clock.clock, automaticChecks: false) { report in
                reports.access { $0.append(report) }
            }
            let provider = DrawingProbe()
            weak var releasedSkin: Skin?
            autoreleasepool {
                let runtime = SkinRuntime(config: "Watchdog", file: "Test.ini", skinsDirectory: root,
                                          executor: executor, content: provider, watchdog: watchdog)
                releasedSkin = runtime.skin
                let loaded = Guarded(false)
                on(executor, t) { loaded.access { $0 = (try? runtime.load()) != nil } }
                guard loaded.current else { t.check(false, "the test skin loads"); return }
                let simulateSlowWork = { clock.advance(by: 3); watchdog.check() }
                let probeFound = Guarded(false)
                on(executor, t) {
                    guard let probe = runtime.skin.measure(named: "Probe") as? WorkProbe else { return }
                    probeFound.access { $0 = true }
                    probe.slowWork = simulateSlowWork
                    // An update clock calls Skin directly. Its nested bang must not reset the same activity.
                    runtime.skin.update()
                }
                t.check(probeFound.current)
                t.equal(reports.current.count, 1, "a direct Core update is watched")
                t.equal(watchdog.activeCount, 0)
                on(executor, t) { runtime.send(.update(hops: 0)) }
                t.equal(reports.current.count, 2, "a runtime message and nested Core hook report once together")

                let callback = DispatchSemaphore(value: 0)
                on(executor, t) { runtime.skin.async { simulateSlowWork(); callback.signal() } }
                t.check(callback.wait(timeout: .now() + 30) == .success, "the skin's queued callback ran")
                on(executor, t) {}
                t.equal(reports.current.count, 3, "async completions have the Core work boundary too")
                provider.onPresent = simulateSlowWork
                on(executor, t) { runtime.frames.drawFirstFrame() }
                t.equal(provider.presented.current, 1, "a real bitmap reached the provider")
                t.equal(reports.current.count, 4)
                t.equal(reports.current.last?.kind, .drawing, "drawing outside an update is watched")

                on(executor, t) { runtime.send(.close(fadeOut: false)) }
                t.check(runtime.didClose)
                t.equal(reports.current.count, 5, "OnCloseAction is still watched")
                t.equal(watchdog.activeCount, 0)
                watchdog.check()
                t.check(!watchdog.hasTimer)
            }
            t.check(AppSelfTest.spin(timeout: 30) { releasedSkin == nil }, "diagnostics do not keep an unloaded skin")
            watchdog.check()
            t.equal(reports.current.count, 5)
        }

        t.suite("App: skin watchdog: main-thread runtimes do not start a worker monitor") {
            MeasureRegistry.registerPlugin("DesksetWatchdogProbe", WorkProbe.self)
            let root = try writeSkin(t)
            let clock = makeClock()
            let reports = Guarded<[SkinWorkWatchdog.Report]>([])
            let watchdog = SkinWorkWatchdog(clock: clock.clock) { report in reports.access { $0.append(report) } }
            let provider = DrawingProbe()
            let runtime = SkinRuntime(config: "Watchdog", file: "Test.ini", skinsDirectory: root,
                                      content: provider, watchdog: watchdog)
            _ = try runtime.load()
            let simulateSlowWork = { clock.advance(by: 3); watchdog.check() }
            (runtime.skin.measure(named: "Probe") as? WorkProbe)?.slowWork = simulateSlowWork
            runtime.send(.update(hops: 0))
            provider.onPresent = simulateSlowWork
            runtime.frames.drawFirstFrame()
            runtime.send(.close(fadeOut: false))
            t.equal(provider.presented.current, 1)
            t.equal(watchdog.activeCount, 0)
            t.equal(watchdog.timerStarts, 0)
            t.equal(reports.current.count, 0)
        }
    }

    private static func on(_ executor: SkinThreadExecutor, _ t: AppTestRunner, _ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        executor.async { body(); done.signal() }
        t.check(done.wait(timeout: .now() + 30) == .success, "the worker completed its bounded test step")
    }

    private static func writeSkin(_ t: AppTestRunner) throws -> URL {
        let root = t.temporaryDirectory("skin-watchdog")
        let folder = root.appendingPathComponent("Watchdog")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        [Rainmeter]
        Update=-1
        OnCloseAction=[!CommandMeasure Probe close]
        [Probe]
        Measure=Plugin
        Plugin=DesksetWatchdogProbe
        [Box]
        Meter=Shape
        Shape=Rectangle 0,0,20,20 | Fill Color 255,0,0,255
        """.write(to: folder.appendingPathComponent("Test.ini"), atomically: true, encoding: .utf8)
        return root
    }

    private final class WorkProbe: Measure {
        var slowWork: (() -> Void)?
        override func computeValue() -> Double {
            skin.execute("[!SetVariable Nested 1]", from: self)
            slowWork?()
            return 1
        }

        override func execute(command: String) {
            if command == "close" { slowWork?() }
        }
    }

    private final class DrawingProbe: ContentProvider {
        var onPresent: (() -> Void)?
        let presented = Guarded(0)
        func present(_ frame: SkinFrame) {
            presented.access { $0 += 1 }
            onPresent?()
        }
        func setVisible(_ visible: Bool) {}
        func setScale(_ scale: CGFloat) {}
        func teardown() {}
    }
}
