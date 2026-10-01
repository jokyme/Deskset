import AppKit
import DesksetCore

/// The optional worker pool uses the same runtime and fixtures as the shared engine thread. These suites exercise
/// the differences: independent workers, stable refresh placement, queued peer bangs and ordered shutdown.
enum EnginePoolSelfTests {
    static func run(_ t: AppTestRunner) {
        lifeTests(t)
        quitBudgetTests(t)
        bangTests(t)
    }

    static func lifeTests(_ t: AppTestRunner) {
        t.suite("App: skin pool: workers draw independently, refresh in place and deliver close actions before quit") {
            guard let app = try AppSelfTest.makeApp(t, threading: .pool) else { return }
            defer { app.endEngineThread() }
            func closing(_ name: String) -> String {
                """
                [Rainmeter]
                Update=1000
                OnCloseAction=[!CommandMeasure MeasureScript "Append('\(name)')" "Engine\\Collector"]

                [Count]
                Measure=Calc
                Formula=Counter

                """ + EngineThreadSelfTests.box
            }
            try EngineThreadSelfTests.write(app, ["Collector": EngineThreadSelfTests.collector,
                                                  "A": closing("A"), "B": closing("B")])
            for (order, name) in ["Collector", "A", "B"].enumerated() {
                app.state.update("Engine\\\(name)") { $0.file = "\(name).ini"; $0.loadOrder = order + 1 }
            }
            let loaded = ["Collector", "A", "B"].compactMap { app.activate(config: "Engine\\\($0)", file: nil) }
            guard loaded.count == 3 else { return t.check(false, "three skins loaded") }
            t.check(AppSelfTest.spin(timeout: 60) { loaded.allSatisfy(\.isStarted) }, "all started")
            let (collector, a, b) = (loaded[0], loaded[1], loaded[2])
            t.equal(app.skinThreadPool?.activeWorkers.count, 2)
            t.check(a.runtime.executor !== b.runtime.executor, "A and B have independent workers")
            t.check(a.runtime.defersPeerBangs && b.runtime.defersPeerBangs)
            for c in loaded { c.visibilityForTesting = true; c.runtime.send(.redraw) }
            t.check(AppSelfTest.spin(timeout: 30) { loaded.allSatisfy { $0.content.state.presented > 0 } },
                    "every worker produced a frame")

            let gate = SkinLifecycleSelfTests.Gate()
            gate.hold(a.runtime.executor)
            let before = b.runtime.snapshot.updateCount
            b.runtime.send(.update(hops: 0))
            t.check(AppSelfTest.spin(timeout: 30) { b.runtime.snapshot.updateCount > before },
                    "B updates while A's worker is held")
            gate.open()

            app.refresh(a)
            guard let next = app.controller(for: "Engine\\A"), next !== a else {
                return t.check(false, "a new instance after refresh")
            }
            t.check(AppSelfTest.spin(timeout: 60) { next.isStarted && a.runtime.didClose }, "refresh settled")
            t.check(next.runtime.executor === a.runtime.executor, "the refreshed config stays on its worker")
            t.check(AppSelfTest.spin(timeout: 30) {
                collector.runtime.exclusive(timeout: 0) { $0.variable("Log") } == "A;"
            }, "refresh delivered its close action")

            let workers = app.skinThreadPool?.activeWorkers ?? []
            t.equal(app.stopAllForTermination(), [], "every skin closed within the quit budget")
            t.check(app.sortedControllers.allSatisfy(\.runtime.didClose))
            t.equal(collector.runtime.exclusive(timeout: 30) { $0.variable("Log") }, "A;B;A;",
                    "reverse load order closes reach the collector on both workers before it closes")
            t.equal(app.state.skin("Engine\\A")?.active, true, "still active for the next launch")
            for worker in workers {
                t.equal(worker.exclusive(timeout: 30) { worker.updateScheduler.pendingCount }, 0,
                        "no periodic updates survive close")
            }
            app.endEngineThread()
            t.check(AppSelfTest.spin(timeout: 30) { workers.allSatisfy(\.hasExited) }, "both workers exit")
        }
    }

    static func quitBudgetTests(_ t: AppTestRunner) {
        t.suite("App: skin pool: a stalled worker leaves quit time for close actions on the other worker") {
            guard let app = try AppSelfTest.makeApp(t, threading: .pool) else { return }
            defer { app.endEngineThread() }
            let text = "[Rainmeter]\nUpdate=-1\nOnCloseAction=[!SetVariable Closed 1]\n\n"
                + "[Variables]\nClosed=0\n\n" + EngineThreadSelfTests.box
            try EngineThreadSelfTests.write(app, ["A": text, "B": text])
            for (order, name) in ["A", "B"].enumerated() {
                app.state.update("Engine\\\(name)") { $0.file = "\(name).ini"; $0.loadOrder = order + 1 }
            }
            guard let a = app.activate(config: "Engine\\A", file: nil),
                  let b = app.activate(config: "Engine\\B", file: nil) else { return t.check(false, "loaded") }
            t.check(AppSelfTest.spin(timeout: 60) { a.isStarted && b.isStarted }, "both started")
            guard a.runtime.executor !== b.runtime.executor else { return t.check(false, "different workers") }
            let beganClose = Guarded<TimeInterval?>(nil)
            _ = a.runtime.exclusive(timeout: 30) { _ in
                a.runtime.messageObserver = { message in
                    if case .close = message { beganClose.access { $0 = ProcessInfo.processInfo.systemUptime } }
                }
            }
            let gate = SkinLifecycleSelfTests.Gate()
            gate.hold(b.runtime.executor)
            defer { gate.open() }
            let budget = 1.0
            let began = ProcessInfo.processInfo.systemUptime
            let late = app.stopAllForTermination(budget: budget)
            let fastClosedInBudget = a.runtime.didClose
            gate.open()
            t.check(AppSelfTest.spin(timeout: 30) { a.runtime.didClose && b.runtime.didClose }, "both eventually close")
            t.check(fastClosedInBudget, "the free worker's skin closes before quit returns")
            t.check(beganClose.current.map { $0 - began < budget } == true,
                    "its close was sent before the shared deadline, even though the first worker stayed busy")
            t.equal(late, ["Engine\\B"], "only the stalled skin missed the budget")
            t.equal(a.runtime.exclusive(timeout: 30) { $0.variable("Closed") }, "1", "its OnCloseAction ran")
        }
    }

    static func bangTests(_ t: AppTestRunner) {
        t.suite("App: skin pool: peer bangs are queued on either worker, stay ordered and stop at the hop limit") {
            guard let app = try AppSelfTest.makeApp(t, threading: .pool) else { return }
            let names = (1...9).map { "Ring\($0)" }
            var files: [String: String] = [:]
            for (i, name) in names.enumerated() {
                files[name] = SkinWindowModelSelfTests.pingSkin("Engine\\\(names[(i + 1) % names.count])")
            }
            try EngineThreadSelfTests.write(app, files)
            var tracked: [() -> Skin?] = []
            autoreleasepool {
                let ring = names.compactMap { app.activate(config: "Engine\\\($0)", file: nil) }
                guard ring.count == names.count else { return t.check(false, "all ring skins loaded") }
                tracked = ring.map(EngineThreadSelfTests.track)
                t.check(AppSelfTest.spin(timeout: 60) { ring.allSatisfy(\.isStarted) }, "all started")
                let source = ring[0]
                guard let same = ring.dropFirst().first(where: { $0.runtime.executor === source.runtime.executor }),
                      let other = ring.first(where: { $0.runtime.executor !== source.runtime.executor }) else {
                    return t.check(false, "peers on both workers")
                }
                // Exclusive access holds the shared worker while the source sends. A peer on it cannot run yet.
                let immediate = source.runtime.exclusive(timeout: 30) { _ -> String? in
                    source.runtime.send(.execute("[!SetVariable Log queued \"\(same.config)\"]", section: nil))
                    return same.runtime.skin.variable("Log")
                }
                t.equal(immediate ?? nil, "", "a peer on the same worker is queued too")
                t.check(AppSelfTest.spin(timeout: 30) {
                    same.runtime.exclusive(timeout: 0) { $0.variable("Log") } == "queued"
                },
                        "then the peer runs")
                // Ordering is per sender, for every worker. Record every bang on the receiving worker.
                for target in [same, other] {
                    let seen = Guarded<[String]>([])
                    _ = target.runtime.exclusive(timeout: 30) { _ in
                        target.runtime.messageObserver = { message in
                            if case .bang(let bang, _, _) = message, bang.name == "setvariable",
                               bang.args.first == "Log", bang.args.count >= 2 {
                                seen.access { $0.append(bang.args[1]) }
                            }
                        }
                    }
                    let action = (1...50).map { "[!SetVariable Log \($0) \"\(target.config)\"]" }.joined()
                    source.runtime.send(.execute(action, section: nil))
                    t.check(AppSelfTest.spin(timeout: 30) { seen.current.count == 50 }, "all peer bangs delivered")
                    t.equal(seen.current, (1...50).map(String.init), "in sender order on either worker")
                    _ = target.runtime.exclusive(timeout: 30) { _ in target.runtime.messageObserver = nil }
                }

                for c in ring {
                    _ = c.runtime.exclusive(timeout: 30) { _ in
                        c.runtime.send(.execute("[!SetVariable Armed 1]", section: nil))
                    }
                }
                let before = ring.map { $0.runtime.snapshot.updateCount }
                source.runtime.send(.update(hops: 0))
                t.check(AppSelfTest.spin(timeout: 30) {
                    ring[7].runtime.exclusive(timeout: 0) { _ in ring[7].runtime.droppedHops } == 1
                }, "the asynchronous ring stops after hop 16")
                t.equal(zip(ring, before).map { $0.runtime.snapshot.updateCount - $1 },
                        [2, 2, 2, 2, 2, 2, 2, 2, 1], "the same hop bound as the shared engine thread")
                t.equal(ring.map { c in c.runtime.exclusive(timeout: 30) { _ in c.runtime.hopLimitLogs } ?? -1 },
                        [0, 0, 0, 0, 0, 0, 0, 1, 0], "one diagnostic for the dropped chain")
                for c in ring { app.deactivate(config: c.config) }
            }
            EngineThreadSelfTests.finish(t, app, tracked)
        }
    }
}
